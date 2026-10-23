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
            // Tall and Wide (docs/DESIGN.md): wider than tall and at least 1000 pt across is Wide (an iPad sideways, the
            // Mac); everything else is Tall, the iPhone app. Measured on the whole window, keyboard included.
            let insets = geometry.safeAreaInsets
            let window = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                height: geometry.size.height + insets.top + insets.bottom)
            let wide = WindowShape.isWide(window: window)
            Group {
            if wide {
                wideLayout(width: geometry.size.width).environment(\.figureViewerWindowSize, geometry.size)
            }
            else {
                // Floating chrome (2026-10-07): the tab bar floats over the screen, whose content scrolls
                // behind it; each screen keeps room for it (`tabBarSpace`) so its last row is reachable.
                // Over a docked find bar, the bar is the bottom safe area: no home indicator below the tabs.
                let safeBottom = geometry.safeAreaInsets.bottom
                // The podcast mini-player rides on the tab bar and takes part of its reserve (PodcastMiniPlayer).
                let miniPlayer = model.podcasts.nowPlaying != nil
                destination(model.tab)
                    .environment(\.figureViewerWindowSize, geometry.size)
                    .environment(\.tabBarReserve, softwareKeyboardShown ? 0
                                 : ChromeMetrics.tabBarReserve(safeBottom: safeBottom) + (miniPlayer ? PodcastMiniPlayer.height : 0))
                    .overlay(alignment: .bottom) {
                        // Drawing a snippet takes the bottom of the screen for its own controls; the reserve stays, so
                        // the page never moves under the box being drawn.
                        if !softwareKeyboardShown && model.notes.capturing == nil {
                            VStack(spacing: 6) {
                                if miniPlayer { PodcastMiniPlayer(model: model) }
                                tabBar
                            }
                                .padding(.horizontal, DesignMetrics.margin)
                                .padding(.bottom, ChromeMetrics.tabBarBottom(safeBottom: safeBottom))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
            }
            }
            .onAppear { model.compactLayout = !wide }
            .onChange(of: wide) { _, now in shapeChanged(toWide: now) }
        }
        // Visual checks pin the appearance (`--appearance=`); nil follows the system.
        .preferredColorScheme(Platform.fixtureAppearance)
        #if DEBUG && FIXTURE_HOST
        .task { await VisualCapture.runIfRequested(model) }
        #endif
        // On the root so the state stays true across wide/compact layout switches.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard's shortcut bar is short; keep the tabs then.
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            softwareKeyboardShown = (frame?.height ?? 0) > 150
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in softwareKeyboardShown = false }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in softwareKeyboardShown = false }
        .onChange(of: model.tab) { _, _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        // Sign-in, recovery, chats, diagrams, credits, reports and errors: presented here, or over Settings while it is
        // open over the screen (SettingsPresentation.swift).
        .sharedPresentations(model, host: .root)
        .infoBubbleDimming()
        .sheet(item: consentPresentation) { prompt in ChatConsentView(model: model, prompt: prompt).interactiveDismissDisabled().macSheetKeys(enabled: false) }
        .sheet(isPresented: $model.showAnswerOptions) { AnswerOptionsSheet(model: model).macSheetKeys() }
        .sheet(item: $model.localPaperPresentation) { presentation in
            LocalPDFReaderView(presentation: presentation, readWithModel: model.modelReadablePaper(for: presentation).map { paper in { model.readWithDeviceModel(paper) } },
                               model: model)
                .macSheetKeys()
        }
        // At the root: deletion signs out, which leaves Settings.
        .alert("Account deleted", isPresented: $model.accountDeletedNotice) { Button("OK") {} } message: {
            Text("Your account and its data were deleted from our servers and this device.")
        }
        .modifier(PodcastPresenter(model: model))
        .sheet(isPresented: $model.showImportHelp) { ImportProgressExplainer().macSheetKeys() }
        .modifier(PDFUploadPresenter(model: model))
        .modifier(DeviceApprovalBanner(model: model))
        .sheet(item: $model.tagEditor) { request in
            if let paper = model.papers.first(where: { $0.id == request.paperID }) { TagEditorView(model: model, paper: paper, keyword: request.keyword) }
        }
        // Settings over the current screen (phone width): the last section of every top-right menu; Done returns here.
        .sheet(isPresented: $model.settingsPresented) {
            SettingsView(model: model, dismissSettings: { model.closeSettings() })
                .sharedPresentations(model, host: .settings)
                .macSheetKeys()
        }
        #if INTERNAL
        .modifier(SessionCaptureHooks(model: model))
        #endif
        #if !targetEnvironment(macCatalyst)
        // A screenshot taken in Gradstep offers "Report this screen" (Settings can turn the offer off).
        .task { ScreenshotReportPrompt.shared.start(model) }
        #endif
        // Scheduled sync (ReaderModel.updateSyncSchedule) follows the scene; the first sync on return is below.
        .onChange(of: scenePhase, initial: true) { _, phase in model.sceneActive = phase == .active }
        .onChange(of: scenePhase) { _, phase in
            Task {
                model.flushReadingActivity()
                await model.flushDrafts()
                if phase == .active {
                    // An episode asked for earlier may be ready now (Listen's own section).
                    model.podcasts.sceneBecameActive()
                    async let history: Void = model.synchronize()
                    async let library: Void = model.refreshLibrary()
                    async let purchases: Void = model.syncStoreTransactions()
                    _ = await (history, library, purchases)
                }
            }
        }
    }

    /// The tab bar: one glass capsule floating over the screen (2026-10-07).
    private var tabBar: some View {
        HStack(spacing: 0) {
            // Feed · Library · Paper · Chat · Notes (owner, 2026-10-20): Settings is the last section of every ⋯ menu.
            ForEach(ReaderTab.phoneTabs) { tab in
                Button {
                    // A second tap on Notes goes back to its list, as a system tab bar does.
                    if tab == .notes && model.tab == .notes { model.notes.openNoteID = nil }
                    model.tab = tab
                } label: { TabBarItem(tab: tab, selected: model.tab == tab) }
                .buttonStyle(.plain)
                .disabled(tab == .paper && model.selectedPaper == nil)
                .opacity(tab == .paper && model.selectedPaper == nil ? 0.35 : 1)
                .accessibilityIdentifier("tab.\(String(describing: tab))")
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Label(tab.rawValue, image: tab.icon) }
            }
        }
        .padding(4)
        .frame(maxWidth: ChromeMetrics.tabBarMaxWidth)
        .chromeSurface(Capsule(), interactive: true)
    }

    /// A system dismissal counts as declining that captured question only.
    private var consentPresentation: Binding<ChatConsentPrompt?> {
        Binding(get: { model.hasContextualChat ? nil : model.chatConsentPrompt }, set: { value in
            if !model.hasContextualChat, value == nil, let prompt = model.chatConsentPrompt { model.declineChatConsent(prompt) }
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
        case .notes: NotesView(model: model)
        // Only after a wide window narrows with Settings showing; Done returns to where it was opened from.
        case .settings: SettingsView(model: model, dismissSettings: { model.closeSettings() })
            #if OFFLINE_RESOURCE_MEASUREMENTS
            .onAppear { OfflineResourceProbe.shared.destinationAppearance(.settings, appeared: true) }
            .onDisappear { OfflineResourceProbe.shared.destinationAppearance(.settings, appeared: false) }
            #endif
        }
    }

    /// Turning an iPad (or resizing a window) between Tall and Wide moves only the places capsule and the chat
    /// (docs/DESIGN.md › Tall and Wide): the paper, its place, the open chat and its draft stay as they were.
    private func shapeChanged(toWide wide: Bool) {
        // An open chat stays open (the Chat tab in Tall, the card over the paper in Wide), with its draft; the paper keeps
        // its place. Nothing else changes.
        model.compactLayout = !wide
        // A paper's chat open on the Chat tab shows beside its paper.
        if wide, model.tab == .chat, !model.generalChat { model.readerChatHidden = false }
        // iPad Settings is a sheet in both shapes; a Mac-style Settings place never shows in Tall.
        if !wide, model.tab == .settings { model.tab = model.placeBeforeSettings; model.settingsPresented = true }
    }

    private func wideLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Reading mode (READING_MODE.md) is the paper alone: no places, panes or docked player.
            if model.readingMode && model.tab != .settings {
                ReadingModeView(model: model)
            } else {
            if model.tab == .settings {
                // The Mac: Settings takes the window's panes; Done returns to the place it was opened from.
                SettingsView(model: model, dismissSettings: { model.closeSettings() })
            } else {
                // Each pane draws its share of the one top row; the main pane's carries the places capsule. On the Mac the
                // places are in the window's toolbar (MacWindowConfiguration).
                switch model.widePlace {
                case .feed: if model.podcasts.listenSelected { PodcastListenView(model: model) } else { FeedView(model: model) }
                case .library: LibraryView(model: model)
                // Two slots, at most two columns (ReaderSplit.swift › WideSlots).
                case .paper:
                    // The Mac keeps the paper beside its chat column (or the library beside the paper) until its own step.
                    if Platform.isMac {
                        if model.wideList == .papers {
                            HStack(spacing: 0) {
                                LibraryView(model: model).frame(width: TwoSlotLayout<EmptyView, EmptyView>.listWidth(for: width))
                                    .environment(\.placesInBar, false).environment(\.librarySidebar, true)
                                Divider()
                                PaperView(model: model).frame(maxWidth: .infinity)
                            }
                        } else { ReaderSplit(model: model, width: width) }
                    } else { WideSlots(model: model, width: width) }
                case .chat:
                    // Chats (iPad Wide): your conversations beside the open one, like Messages.
                    if Platform.isMac { ChatView(model: model) } else {
                        TwoSlotLayout(width: width, other: .left) {
                            ChatView(model: model).environment(\.chatsList, true)
                        } otherView: {
                            ChatHistoryView(model: model, embedded: true)
                        }
                    }
                // Notes as list + detail; it never replaces the reader's chat pane.
                case .notes, .settings: NotesView(model: model, wide: true, width: width)
                }
            }
            // The podcast player docks along the bottom, below every pane (none of their controls go under it).
            if model.podcasts.nowPlaying != nil {
                Divider()
                PodcastMiniPlayer(model: model, wide: true).padding(.vertical, 6).frame(maxWidth: .infinity)
            }
            }
        }
        .environment(\.wideReader, true)
        .environment(\.wideBar, !Platform.isMac)
        .environment(\.placesInBar, !Platform.isMac)
        // A narrow window (an iPad split) has no reading mode: it ends rather than hide everything.
        .onDisappear { model.exitReadingMode() }
        #if targetEnvironment(macCatalyst)
        .background(MacWindowConfiguration(model: model, place: model.widePlace, settingsShown: model.tab == .settings, reading: model.readingMode))
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
    /// The Wide shape (WideShape.swift): the header is this pane's share of the one top row.
    @Environment(\.wideBar) private var wideBar
    @Environment(\.placesInBar) private var placesInBar
    /// Browse's list beside the paper: rows, never the table (audit N8).
    @Environment(\.librarySidebar) private var sidebar
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
                        Text(model.searchExternal ? "Search ML papers to add one." : "Add a paper to read and ask questions.")
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
            // searching: Cancel, and the Library / ML paper search switch under the field (named by the owner, 2026-10-16).
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .tabBarSpace()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: model.searchExternal) { _, external in
                if external, model.discoveryState == .idle, !model.discoveryQuery.trimmingCharacters(in: .whitespaces).isEmpty { model.runDiscovery() }
            }
            // A search starts from the whole library: an earlier tag filter would hide results without saying so
            // (build 75: "I somehow got here, I wonder if a search was not escaped").
            .onChange(of: searching) { _, now in if now { model.libraryTagFilter = nil } }
            // Mac menu bar: Edit › Search Library (⌘F) / Search ML Papers (⇧⌘F).
            .onChange(of: MacCommandRequests.shared.librarySearch, initial: true) { _, request in
                if request != nil { MacCommandRequests.shared.librarySearch = nil; searchFocused = true }
            }
            .sheet(isPresented: $model.showImport) { ImportPaperView(model: model) }
            .sheet(isPresented: $model.showLibraryChanges) { LibraryChangesView(model: model).macSheetKeys() }
            .sheet(isPresented: $model.showCatalogs) { LibraryCatalogsView(model: model).macSheetKeys() }
        }
    }

    private var searching: Bool { searchFocused || !model.searchQuery.isEmpty || model.searchExternal }
    /// The table spans the pane; everything else sits in the readable column. At accessibility text sizes the
    /// table shows the List's rows (DESIGN.md › Tables).
    private var tableShown: Bool {
        model.libraryLayout == .table && !model.searchExternal && !dynamicTypeSize.isAccessibilitySize && !sidebar
    }

    private func clearFilters() { model.libraryFilter = .all; model.libraryTagFilter = nil }

    /// Only states the reader can act on; none while browsing normally.
    @ViewBuilder private func banners(inset: Bool) -> some View {
        let signIn = !model.isSignedIn && !searching
        let issue = model.searchExternal ? nil : model.libraryIssue
        let pending = model.searchExternal ? nil : model.librarySyncNotice
        let offline = model.searchExternal ? nil : model.offlineCacheIssue
        let uploading = !model.searchExternal && PDFUploadBanners.shows(model)
        if signIn || issue != nil || pending != nil || offline != nil || uploading {
            VStack(spacing: 8) {
                if uploading { PDFUploadBanners(model: model) }
                if signIn {
                    StatusBannerLink(tone: .info, systemImage: "lock.icloud", message: "Sign in to sync") { model.openSignIn() }
                        .accessibilityIdentifier("library.signIn")
                    if let issue = model.sessionEndedIssue {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("library.sessionEnded")
                    }
                }
                if let issue {
                    StatusBanner(tone: .problem, systemImage: "exclamationmark.arrow.triangle.2.circlepath", message: issue) {
                        Button("Retry") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing)
                    }.accessibilityIdentifier("library.refreshIssue")
                }
                // Build 73: quiet until a change has waited or keeps failing; orange only when the reader must act.
                if case .needsAction(let message)? = pending {
                    StatusBanner(tone: .problem, systemImage: "exclamationmark.arrow.triangle.2.circlepath", message: message,
                                 messageID: "library.syncNotice") {
                        if !model.libraryCommands.isEmpty {
                            Button("Review") { model.showLibraryChanges = true }.accessibilityIdentifier("library.pendingChanges")
                        }
                    }
                } else if case .waiting(let count)? = pending {
                    StatusBanner(tone: .info, systemImage: "arrow.triangle.2.circlepath",
                                 message: count == 1 ? "1 change hasn’t synced yet. Gradstep will keep trying."
                                    : "\(count) changes haven’t synced yet. Gradstep will keep trying.", messageID: "library.syncNotice") {
                        Button("Details") { model.showLibraryChanges = true }.accessibilityIdentifier("library.pendingChanges")
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
    private var highlightsSelection: Bool { model.browsing && Platform.isLargeScreen }

    /// The catalog beside the search field when there is a choice of catalogs (owner, build 75: "Move the catalog to the
    /// left of the search bar and move the + option as a new row inside the dialogue on the far right").
    private var showsCatalog: Bool {
        !searching && (model.libraryCatalogs.catalogs.count > 1 || model.currentCatalog.name != "Default")
    }

    @ViewBuilder private var header: some View {
        if wideBar { wideHeader } else { phoneHeader }
    }

    private var searchField: some View {
        LibrarySearchField(text: $model.searchQuery, prompt: model.searchExternal ? "Search ML papers" : "Search",
                           focused: $searchFocused) { if model.searchExternal { model.runDiscovery() } }
    }

    private func cancelSearch() {
        // Back to the whole library: no tag filter is left behind (build 75).
        model.searchExternal = false; model.libraryQuery = ""; model.discoveryQuery = ""; model.libraryTagFilter = nil
        searchFocused = false
    }

    /// Wide: one row. The Library: its search field (as on iPhone), the places capsule, then ⋯ (Cancel while searching).
    /// The panel beside the paper: the field at its top, like Mail, with the Library / ML paper search switch under it.
    private var wideHeader: some View {
        VStack(spacing: 0) {
            if sidebar { panelRow } else { libraryRow }
            if sidebar || searching {
                VStack(spacing: 10) {
                    Picker("Search", selection: $model.searchExternal) { Text("Library").tag(false); Text("ML paper search").tag(true) }
                        .pickerStyle(.segmented).accessibilityIdentifier("library.searchScope")
                    if model.searchExternal { AdvancedPaperSearch(model: model) }
                }
                .modifier(PanelOrColumn(panel: sidebar)).padding(.vertical, 8)
                .chromeBand(.top, solid: true)
            }
        }
        .animation(.snappy(duration: 0.2), value: searching)
    }

    private var libraryRow: some View {
        WideBar {
            WideSearchField { searchField }.frame(width: 280)
        } center: {
            if placesInBar { WidePlacesCapsule(model: model) }
        } trailing: {
            if searching { Button("Cancel") { cancelSearch() }.accessibilityIdentifier("library.search.cancel") } else { optionsMenu }
        }
    }

    /// The library beside the paper: the field fills the panel's row; ✕ closes the panel, Cancel (or Esc) ends a search and
    /// puts the panel back as it was before Search opened it.
    private var panelRow: some View {
        WideBar {
            WideSearchField { searchField }
        } center: {
            EmptyView()
        } trailing: {
            if searching {
                Button("Cancel") { endPanelSearch() }.accessibilityIdentifier("library.search.cancel")
                Button("Cancel search") { endPanelSearch() }.keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            } else {
                Button { model.setLibraryBesidePaper(false) } label: { HeaderButtonLabel(systemImage: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close library").accessibilityIdentifier("library.panel.close")
            }
        }
    }

    private func endPanelSearch() {
        cancelSearch()
        model.endPapersSearch()
    }

    private var phoneHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if showsCatalog { catalogMenu }
                searchField
                    .padding(.leading, 10).padding(.trailing, 6).frame(height: DesignMetrics.headerControl)
                    .chromeSurface(Capsule())
                if searching {
                    Button("Cancel") { cancelSearch() }.accessibilityIdentifier("library.search.cancel")
                } else {
                    optionsMenu
                }
            }
            if searching {
                Picker("Search", selection: $model.searchExternal) { Text("Library").tag(false); Text("ML paper search").tag(true) }
                    .pickerStyle(.segmented).accessibilityIdentifier("library.searchScope")
                if model.searchExternal { AdvancedPaperSearch(model: model) }
            }
        }
        .modifier(HeaderWidth(fullWidth: tableShown))
        .padding(.top, 2).padding(.bottom, 8)
        // Floating chrome (2026-10-07): rows scroll under the header and fade out behind it. Over the table
        // the band stays solid: the table's column titles pin right below it.
        .chromeBand(.top, solid: tableShown)
        .animation(.snappy(duration: 0.2), value: searching)
    }

    /// The current catalog as a compact glass control (its name truncates), choosing another or managing them.
    private var catalogMenu: some View {
        Menu {
            ForEach(model.libraryCatalogs.catalogs) { catalog in
                Button(catalog.name, systemImage: model.currentCatalog.id == catalog.id ? "checkmark" : "folder") {
                    model.selectCatalog(catalog.id)
                }
            }
            Divider()
            // No ellipsis (owner, build 78: "No three dots after manage catalogs").
            Button("Manage catalogs") { model.showCatalogs = true }
        } label: {
            // A long name is shortened so the search field keeps most of the row.
            let name = model.currentCatalog.name
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(name.count > 14 ? String(name.prefix(13)).trimmingCharacters(in: .whitespaces) + "…" : name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12).frame(height: DesignMetrics.headerControl)
            .fixedSize()
            .chromeSurface(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Catalog: \(model.currentCatalog.name)")
        .accessibilityIdentifier("library.catalog")
    }

    /// Every Library option behind one button (design audit F3): how the list looks, as submenus that
    /// show the current choice, then where else to go, then reporting.
    private var optionsMenu: some View {
        Menu {
            // Add is the first row here (owner, build 75), not a + beside the field.
            Section {
                MenuRow("Add paper…", systemImage: "plus") {
                    if model.librarySignInRequired { model.openSignIn() } else { model.showImport = true }
                }.accessibilityIdentifier("library.add")
            }
            Section {
                // Wide: the catalog choice lives here (the row has no room for it beside the places capsule).
                if wideBar && (model.libraryCatalogs.catalogs.count > 1 || model.currentCatalog.name != "Default") {
                    Menu {
                        Picker("Catalog", selection: Binding(get: { model.currentCatalog.id }, set: { model.selectCatalog($0) })) {
                            ForEach(model.libraryCatalogs.catalogs) { Text($0.name).tag($0.id) }
                        }.pickerStyle(.inline)
                    } label: {
                        Label { Text("Catalog"); Text(model.currentCatalog.name) } icon: { menuIcon("folder") }
                    }
                    .accessibilityIdentifier("library.catalog")
                }
                MenuRow("Catalogs", systemImage: "folder") { model.showCatalogs = true }
                RecommendCatalogMenu(model: model)
            }
            Section {
                Menu {
                    Picker("View as", selection: $model.libraryLayout) {
                        ForEach(LibraryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Label { Text("View as"); Text(model.libraryLayout.title) } icon: { menuIcon("rectangle.grid.1x2") }
                }
                // Wide only: the library's list beside the paper (Browse, a place of its own before 2026-10-22).
                if !model.compactLayout {
                    Toggle(isOn: Binding(get: { model.libraryBesidePaper }, set: { model.setLibraryBesidePaper($0) })) {
                        Label { Text("Show library beside paper") } icon: { menuIcon("sidebar.left") }
                    }
                    .accessibilityIdentifier("library.browse")
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
                SettingsMenuSection(model: model)
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
                        let copy = model.deviceCopy(for: paper)
                        PaperRow(paper: paper, selected: highlightsSelection && model.selectedPaper?.id == paper.id, deviceCopy: copy,
                                 isNew: model.isNew(paper), status: model.libraryStatus(for: entry),
                                 showAbstract: model.showAbstracts, showTopics: model.showTopics)
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("paper.\(paper.id.wire)")
                        .contextMenu { LibraryRowActions(model: model, entry: entry) }
                        // The cloud symbol's tap: download without opening (as the table's), beside the row's button.
                        .overlay(alignment: .topTrailing) {
                            if model.deviceCopy(for: paper) == .cloud {
                                Button { model.prepareOnDevice(paper) } label: { Color.clear.frame(width: 44, height: 36).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).accessibilityLabel("Download to this device").help("Download to this device")
                                    .accessibilityIdentifier("paper.\(paper.id.wire).download")
                            }
                        }
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
            if let authors = LibraryFormat.shortAuthors(item.metadata?.authors ?? []) {
                Text(authors).font(.subheadline).foregroundStyle(.secondary)
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

/// The List layout's row (and the only layout at accessibility text sizes). It says what the table's title cell says
/// (audit 2026-10-15): what this device holds (the check, or the cloud to tap to download), "New" for a recent paper not
/// opened yet (build 75: words, not a dot), and a download or problem in words.
struct PaperRow: View {
    let paper: Paper
    var selected = false
    var deviceCopy: PaperDeviceCopy? = nil
    var isNew = false
    var status: LibraryRowFacts.Status = .none
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
                // The cloud's tap target is the list's overlay beside this row's button (a button inside a button's
                // label doesn't get its own taps).
                if let copy = deviceCopy {
                    Image(systemName: copy.symbol).foregroundStyle(copy == .reader || copy == .pdf ? Color.accentColor : copy == .unavailable ? Color.orange : Color.secondary)
                        .accessibilityLabel(copy.label).help(copy.label)
                }
            }
            if let authors = LibraryFormat.shortAuthors(for: paper) { Text(authors).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1) }
            switch status {
            case .active(let text):
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(text).monospacedDigit() }.font(.footnote).foregroundStyle(.secondary)
            case .problem(let text): Text(text).font(.footnote).foregroundStyle(.orange)
            case .info, .none: EmptyView()
            }
            if showAbstract && !paper.abstract.isEmpty { Text(paper.abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            let source = LibrarySource.badge(sourceID: paper.sourceID, revision: paper.sourceRevision).map { [$0] } ?? []
            let metadata = (isNew ? ["New"] : []) + (paper.archived ? ["Archived"] : []) + (paper.year.map { [String($0)] } ?? []) + source
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
    /// The Wide shape: the places capsule and ⋯ in the one top row; the topic chips lead the content.
    @Environment(\.wideBar) private var wideBar
    /// Browse's left slot after opening a paper from the Feed: its rows beside the paper.
    @Environment(\.librarySidebar) private var sidebar
    private var isFailed: Bool { if case .failed = model.feedState { true } else { false } }
    /// The table spans the pane (its header too); at accessibility text sizes it shows as the list.
    private var tableShown: Bool {
        model.feedLayout == .table && !dynamicTypeSize.isAccessibilitySize && model.feedState == .loaded && !model.feedResults.isEmpty && !sidebar
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Wide: the topics lead the content (the list and table carry them as their first row).
                if wideBar && !(model.feedState == .loaded && !model.shownFeedResults.isEmpty) {
                    FeedChipsRow(model: model).padding(.horizontal, DesignMetrics.margin).padding(.top, 8)
                }
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
                        if let stale = model.feedStaleNote {
                            StatusBanner(tone: .info, systemImage: "clock.arrow.circlepath", message: stale, messageID: "feed.stale") { EmptyView() }
                                .padding(.horizontal, DesignMetrics.margin).padding(.top, 6)
                        }
                        FeedTable(model: model, issue: $issue, showsChips: wideBar).refreshable { model.loadFeed() }
                    } else {
                        List {
                            if let issue {
                                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue).listRowSeparator(.hidden)
                            }
                            if let stale = model.feedStaleNote {
                                StatusBanner(tone: .info, systemImage: "clock.arrow.circlepath", message: stale, messageID: "feed.stale") { EmptyView() }.listRowSeparator(.hidden)
                            }
                            if wideBar {
                                FeedChipsRow(model: model).listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 8, leading: DesignMetrics.margin, bottom: 4, trailing: 0))
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
                if model.feedState == .loaded && !model.feedResults.isEmpty && !sidebar {
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

    @ViewBuilder private var header: some View {
        if wideBar && sidebar {
            WideBar { Text("Feed").font(.headline).accessibilityAddTraits(.isHeader) } trailing: {
                Button { model.wideList = .none } label: { HeaderButtonLabel(systemImage: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close feed").accessibilityIdentifier("feed.panel.close")
            }
        } else if wideBar {
            WideBar { WidePlacesCapsule(model: model) } trailing: { optionsMenu }
        } else { phoneHeader }
    }

    private var phoneHeader: some View {
        HStack(spacing: 10) {
            if isFailed {
                PodcastListenChip(model: model)
                Text("Feed").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FeedChipsRow(model: model)
            }
            optionsMenu
        }
        .modifier(HeaderWidth(fullWidth: tableShown)).padding(.top, 2).padding(.bottom, 8)
        .chromeBand(.top, solid: tableShown)
    }

    /// Every Feed option behind one button.
    private var optionsMenu: some View {
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
            SettingsMenuSection(model: model)
        } label: { HeaderButtonLabel(systemImage: "ellipsis") }
        .buttonStyle(.plain).accessibilityLabel("Feed options")
    }
}

/// Listen and the Feed's topic chips, scrolling sideways and fading out at the edge (instead of sliding under ⋯).
struct FeedChipsRow: View {
    @Bindable var model: ReaderModel
    var body: some View {
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
    /// The Wide shape (WideShape.swift): the chat's share of the one top row replaces the navigation bar.
    @Environment(\.wideBar) private var wideBar
    /// The Chat place in Wide: the row carries the places capsule, the title moves beside All chats.
    @Environment(\.placesInBar) private var placesInBar
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
            .navigationBarHiddenInWide(wideBar)
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
            if wideBar { wideRow }
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
                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue.message(free: model.creditBalance?.free), actionsBelow: true,
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
            // Study mode (2026-10-22): one slim row above the message box while the chat is studying.
            if model.chatStudying {
                StudyModeRow(model: model) { composerFocused = false }.readableColumn()
            }
            if let issue = model.chatDraftIssue {
                HStack {
                    Text(issue).font(.caption)
                    Button("Retry") { model.retryDraftSave() }.font(.caption.weight(.semibold))
                }.padding(.horizontal, 16).accessibilityIdentifier("chat.draftIssue")
            }
            // Wide: nothing under the message box (docs/DESIGN.md › Tall and Wide); its status sits above it.
            if wideBar { syncLine }
            composer(compact: compact).readableColumn()
            if !wideBar { syncLine }
        }
        // Close above the tab bar (owner feedback, build 14: "space below chat box not well used").
        .padding(.top, 6).padding(.bottom, tabBarReserve > 0 ? 2 : 8)
        .frame(maxWidth: .infinity)
        // An empty chat has nothing under the message box to fade out, and its glow runs on behind it (no seam). The band
        // stays hit-testable even then: without a background, iPad's taps on the message box fell through to the
        // transcript beneath and the box never took the focus.
        .background {
            if model.chatIsEmpty { Color.black.opacity(0.001) }
            else { ChromeFade(edge: .bottom, color: .chromeBackground, solid: false) }
        }
    }

    /// Design audit F8: sync status only when something needs attention.
    @ViewBuilder private var syncLine: some View {
        if model.isGenerating { ProgressView("Saving…").font(.caption) }
        else if let issue = model.syncIssue { Text(issue).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.secondary) }
    }

    /// Wide: the chat's share of the one top row. Beside the paper: All chats · title ⌄ · New chat · ⋯. The Chat place:
    /// All chats and the title, the places capsule centred, then New chat · ⋯.
    private var wideRow: some View {
        WideBar {
            if !chatsList {
                Button { composerFocused = false; model.openAllChats(paper: chatsPaperID) } label: { HeaderButtonLabel(image: GradstepSymbol.chats) }
                    .buttonStyle(.plain).accessibilityLabel("Chat history").accessibilityIdentifier("chat.history")
            }
            if placesInBar { wideTitle(lines: 1, centred: false) }
        } center: {
            if placesInBar { WidePlacesCapsule(model: model) } else { wideTitle(lines: besidePaper && !model.generalChat ? 2 : 1, centred: true) }
        } trailing: {
            // Discuss: All chats · title · ⋯ · ✕ (New chat is in ⋯). Elsewhere: New chat, then ⋯.
            if !discussChat {
                Button { model.newChat(general: model.generalChat); composerFocused = true } label: { HeaderButtonLabel(image: GradstepSymbol.newChat) }
                    .buttonStyle(.plain).accessibilityLabel("New chat")
            }
            Menu { optionsMenuContent } label: { HeaderButtonLabel(systemImage: "ellipsis") }
                .buttonStyle(.plain).accessibilityLabel("Chat options")
            if discussChat {
                Button { composerFocused = false; model.tab = .paper } label: { HeaderButtonLabel(systemImage: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close chat").accessibilityIdentifier("chat.close")
            }
        }
    }

    /// Discuss's chat (WideSlots) and the Chats view's (beside All chats).
    @Environment(\.discussChat) private var discussChat
    @Environment(\.chatsList) private var chatsList

    /// The title menu in the Wide row: the whole title (two lines beside the paper, audit N9), "General chat" under it.
    private func wideTitle(lines: Int, centred: Bool) -> some View {
        Menu { titleMenuContent } label: {
            VStack(alignment: centred ? .center : .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.chatTitle).font(.system(size: lines > 1 ? 15 : 17, weight: .semibold)).lineLimit(lines)
                        .multilineTextAlignment(centred ? .center : .leading)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }.foregroundStyle(.primary)
                if model.generalChat && lines == 1 {
                    Text("General chat").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.context")
        .accessibilityLabel("Conversation: \(model.chatTitle)")
        .accessibilityValue(model.generalChat ? "General chat" : "Paper chat")
        .accessibilityHint(chatsPaperID == nil ? "Switches between paper chat and general chat"
                           : "Switches between paper chat and general chat, or opens another chat about this paper")
    }

    /// The message box, a view of its own: the only part of the chat screen that reads the draft, so typing re-renders
    /// it alone (NATIVE_REVIEW_20261021 C6).
    private func composer(compact: Bool) -> some View {
        ChatComposerBox(model: model, focused: $composerFocused, compact: compact)
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
                        composerFocused = false; model.openAllChats(paper: paper, thisPaper: true)
                    }
                    .accessibilityIdentifier("chat.paperChats.all")
                }
            }
        }
    }

    /// iPad/Mac Reader layout: the paper is already open beside the chat (set by ReaderSplit for its chat column).
    @Environment(\.chatBesidePaper) private var besidePaper

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
        VStack(alignment: .leading, spacing: 1) {
            Menu {
                titleMenuContent
            } label: {
                HStack(spacing: 3) {
                    Text(visibleTitle).font(.system(size: titleFontSize, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }.foregroundStyle(.primary).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

    /// The title's menu: Go to passage, Rename, Paper chat / General chat, the paper's other chats.
    @ViewBuilder private var titleMenuContent: some View {
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
    }

    /// Design audit F2: the same "…" as every screen — text size, diagrams, reporting.
    private var optionsMenu: some View {
        Menu { optionsMenuContent } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Chat options")
    }

    @ViewBuilder private var optionsMenuContent: some View {
            // Discuss's bar has no New chat button of its own.
            if discussChat {
                Section {
                    MenuRow("New chat", systemImage: GradstepSymbol.newChat) { model.newChat(general: model.generalChat); composerFocused = true }
                        .accessibilityIdentifier("chat.newChat")
                }
            }
            ControlGroup {
                MenuRow("Smaller text", systemImage: "textformat.size.smaller") { model.chatFontSize = max(13, model.chatFontSize - 1) }
                MenuRow("Larger text", systemImage: "textformat.size.larger") { model.chatFontSize = min(26, model.chatFontSize + 1) }
            }.controlGroupStyle(.compactMenu)
            // Owner, build 57: "put the chat settings in the top right drop down… Please also put in there Enter Study Mode".
            Section {
                Button { composerFocused = false; model.showAnswerOptions = true } label: {
                    Label { Text("Answer options…"); Text(ChatProfileText.summary(model.chatProfile, table: model.chatProfileTable)) }
                        icon: { Image(systemName: "slider.horizontal.3") }
                }.accessibilityIdentifier("chat.profile")
                // Study mode (reworked 2026-10-22): a tutor that quizzes you and explains when you need it.
                if model.chatStudying {
                    MenuRow("End study mode", systemImage: "graduationcap") { model.endStudy() }.accessibilityIdentifier("chat.study.end")
                } else if model.canStudyPaper {
                    Button { composerFocused = false; Task { await model.startStudy() } } label: {
                        Label { Text("Study mode"); Text("Quiz me and help me learn") } icon: { Image(systemName: "graduationcap") }
                    }.accessibilityIdentifier("chat.study.start")
                }
            }
            Section {
                GoToPassageMenuRow(model: model) { composerFocused = false }
                MenuRow("All chats", systemImage: GradstepSymbol.chats) { composerFocused = false; model.openAllChats(paper: chatsPaperID) }
                MenuRow("All diagrams", systemImage: "square.stack.3d.up") { composerFocused = false; model.showDiagrams = true }
            }
            // Beside the paper in Wide, the paper's ⋯ is the screen's menu: Report and Settings are there once (audit N4).
            if !(wideBar && besidePaper) {
                Section {
                    MenuRow("Report this screen", systemImage: "ladybug") { composerFocused = false; model.beginReport(afterMenu: true) }
                    SettingsMenuSection(model: model) { composerFocused = false }
                }
            }
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
    @AppStorage(ScreenshotReportPrompt.enabledKey) private var screenshotPrompt = true
    /// A count in Your assets: "None" when empty, as Downloaded papers.
    static func count(_ value: Int) -> String { value > 0 ? value.formatted() : "None" }

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
                            // Owner, build 57: "The Signed in with email code is an unnecessary detail, simplify" (the Account
                            // page still lists how you sign in).
                            let sync = SyncSummary.from(status: model.syncStatus, issue: model.syncIssue, pending: model.publishedPendingCount)
                            AccountRow(name: AccountFormat.name(email: model.email, providers: model.signInProviders), detail: sync.short)
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
                    if !model.isSignedIn {
                        Text(model.sessionEndedIssue ?? "Sign in to sync your library and chats between your devices.")
                            .accessibilityIdentifier("account.signInExplanation")
                    }
                }
                if model.isSignedIn && model.chatTransport != nil {
                    Section {
                        if let balance = model.creditBalance {
                            LabeledContent { Text(balance.availableLabel) } label: {
                                LabelWithInfo(title: "Available", info: "Each AI answer uses credits based on the question, the conversation, the paper’s length and the answer.",
                                              identifier: "settings.credits.info")
                            }
                            .accessibilityIdentifier("settings.credits.available")
                            if balance.reserved > 0 {
                                LabeledContent("Held for answers in progress", value: balance.reserved.formatted())
                            }
                        } else if let issue = model.creditBalanceIssue {
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Available", value: "Loading…")
                        }
                        // Plans and free AI (2026-10-22, docs/PRICING_HOW_IT_WORKS.md): the plan with how pricing works, and
                        // this month's free AI for accounts on the free tier.
                        if model.creditBalance?.unlimitedTesting != true || model.storeSummary?.planName != nil {
                            LabeledContent { Text(model.storeSummary?.planName ?? "Free").accessibilityIdentifier("settings.plan") } label: {
                                LabelWithInfo(title: "Plan", info: FreeAIText.planInfo, identifier: "settings.plan.info")
                            }
                        }
                        if let free = model.creditBalance?.free {
                            LabeledContent("Free AI this month") { Text(FreeAIText.settingsValue(free)).accessibilityIdentifier("settings.freeAI") }
                        }
                        // Owner, 2026-10-22: where credits go — each request with its tokens and cost (AIUsageView.swift).
                        NavigationLink { AIUsageView(model: model) } label: { Text("Your AI usage") }
                            .accessibilityIdentifier("settings.aiUsage")
                        Button("Get credits") { model.showStore = true }
                            .disabled(!model.canPurchase).accessibilityIdentifier("settings.getCredits")
                    } header: { Text("AI credits") }
                }
                if model.chatTransport != nil {
                    Section {
                        ForEach(AIUseCase.allCases) { scenario in
                            NavigationLink { AIScenarioDefaults(model: model, scenario: scenario) } label: {
                                LabeledContent(scenario.title, value: model.localDefault(for: scenario).map { "\(model.localAI.name($0)) (local)" }
                                    ?? (model.chatProfileTable?.label(model.profileDefault(for: scenario).model) ?? model.profileDefault(for: scenario).model.label))
                            }.accessibilityIdentifier("settings.aiScenario.\(scenario.rawValue)")
                        }
                        // Owner, 2026-10-21: "Podcasts is missing from defaults in model settings" — who writes new episodes.
                        if model.podcasts.writerSettingAvailable {
                            NavigationLink { PodcastWriterDefaults(model: model) } label: {
                                LabeledContent("Podcasts", value: model.podcasts.effectiveDefaultWriter?.label ?? "Default")
                            }
                            .accessibilityIdentifier("settings.aiScenario.podcasts")
                            .onAppear { model.podcasts.prepareListen() }
                        }
                    } header: {
                        // Owner, 2026-10-21: "an explainer saying some considerations when choosing the default for each category".
                        AIDefaultsHeader(title: "AI defaults by activity", info: AIDefaultsGuide.section, identifier: "settings.aiDefaults.guide")
                    }
                    // Owner, build 59: "it should say default options for new chats… the actual toggles belong with the
                    // rest of the toggles, all the info can stay in the special info section… accessible with another
                    // info icon".
                    Section {
                        #if targetEnvironment(macCatalyst)
                        NavigationLink { LocalAISettingsView(model: model) } label: {
                            LabeledContent("Local models", value: model.localAIDefaultModelID.map { model.localAI.name($0) } ?? "Downloads and device testing")
                        }.accessibilityIdentifier("settings.localModels")
                        #endif
                        Toggle(isOn: $model.visualAnswers) {
                            LabelWithInfo(title: "Visual answers", info: "Lets the assistant draw diagrams and explanations beside its answers; off, it answers in prose.")
                        }
                        .accessibilityIdentifier("settings.visualAnswers")
                    } header: {
                        HStack(spacing: 4) {
                            Text("AI options")
                            NavigationLink { AIChatOptionsView(model: model) } label: {
                                Image(systemName: "info.circle").font(.system(size: 14)).frame(width: 30, height: 24)
                            }
                            .accessibilityLabel("About AI chat options").accessibilityIdentifier("settings.aiChatInfo")
                        }
                    }
                    .task { model.refreshChatProfiles(); await model.localAI.refresh() }
                }
                Section {
                    Toggle(isOn: $model.autoDownloadNewPapers) {
                        LabelWithInfo(title: "Download new papers", info: "A paper added from the Feed or by its arXiv id downloads and prepares on this device right away, so it opens at once. Off, a paper downloads when you open it or tap its cloud symbol.")
                    }
                    .accessibilityIdentifier("settings.autoDownload")
                } header: { Text("Library") }
                // The experimental on-device model (docs/architecture/DEVICE_PDF_ROUTE.md): only in builds that carry it.
                if DeviceModelEngine.available {
                    Section {
                        Toggle(isOn: $model.deviceModelReader) {
                            LabelWithInfo(title: "On-device PDF reader", info: "Reads a paper’s PDF on this device with Gradstep’s own models: layout, formulas and text, nothing sent anywhere. It takes minutes and can be wrong; formulas it is unsure of are shown as images of the page. Choose “Read with the on-device model” in a paper’s options, then report what you see.")
                        }
                        .accessibilityIdentifier("settings.deviceModel")
                    } header: { Text("Experimental") }
                }
                // Text sizes live where you read and chat (A− / A+ on the paper, the chat's ⋯ menu; owner, build 57).
                Section("Reading") {
                    ThemePicker(selection: $model.appearance)
                    Toggle("Underline passages with chats", isOn: $model.showsPassageMarks)
                        .accessibilityIdentifier("settings.passageMarks")
                }
                // Design audit F11: rows that open something look alike (title + chevron); actions are tinted.
                // Owner, build 57: "Research -> Your Assets… chats, diagrams one word is enough".
                Section("Your assets") {
                    openRow("Chats") { model.showAllChats = true }.accessibilityIdentifier("settings.chats")
                    openRow("Diagrams") { model.showDiagrams = true }.accessibilityIdentifier("settings.diagrams")
                    // Owner, 2026-10-21: "Needs to be a Notes section in your assets". Opens Notes (closing Settings).
                    Button {
                        model.closeSettings(); model.notes.openNoteID = nil; model.tab = .notes
                    } label: {
                        // Owner, build 82: the count without a chevron looked unlike the rows around it.
                        HStack {
                            LabeledContent("Snippets", value: Self.count(model.notes.shownNotes.count))
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }.foregroundStyle(Color.primary).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("settings.notes")
                    // Owner, build 62: "Equation Explanations, and Figure Explanations in the list of your assets".
                    NavigationLink { KeptExplanationsView(model: model, kind: .equations) } label: {
                        LabeledContent("Equation explanations", value: Self.count(model.keptEquationExplanations.count))
                    }.accessibilityIdentifier("settings.equationExplanations")
                    NavigationLink { KeptExplanationsView(model: model, kind: .figures) } label: {
                        LabeledContent("Figure explanations", value: Self.count(model.keptFigureExplanations.count))
                    }.accessibilityIdentifier("settings.figureExplanations")
                    // The paper's AI Explainer (2026-10-22, LEARNING_GUIDE.md): "Saved per paper like other explanations".
                    NavigationLink { KeptExplanationsView(model: model, kind: .papers) } label: {
                        LabeledContent("Paper explanations", value: Self.count(model.keptPaperExplanations.count))
                    }.accessibilityIdentifier("settings.paperExplanations")
                    // Owner, build 59: "a downloaded papers section… that will allow you to delete them".
                    NavigationLink { DownloadedPapersView(model: model) } label: {
                        let bytes = model.downloadedPapers.reduce(0) { $0 + $1.totalBytes }
                        LabeledContent("Downloaded papers", value: bytes > 0 ? DownloadedPapersView.size(bytes) : "None")
                    }.accessibilityIdentifier("settings.downloads")
                    // Owner, build 82: "Need a download assets button". The reader's own content as a .zip made here.
                    if model.isSignedIn { AssetsExportRow(model: model) }
                }
                // Owner feedback, build 14 #9: version, privacy and acknowledgements behind one row at the bottom.
                Section {
                    Button("Report a problem") { model.beginReport() }.accessibilityIdentifier("settings.report")
                    openRow("My reports") { model.showReports = true }.disabled(model.support == nil)
                    #if !targetEnvironment(macCatalyst)
                    Toggle("Offer to report after a screenshot", isOn: $screenshotPrompt).accessibilityIdentifier("settings.screenshotPrompt")
                    #endif
                    NavigationLink("About Gradstep") { AboutView(version: Self.version) }.accessibilityIdentifier("settings.about")
                }
                // Owner, build 57: "Testing and Admin should go in a special section for Admins with Grey background".
                if showsAdmin {
                    Section {
                        if !model.operatorRoles.isEmpty {
                            // The owner's monitoring (docs/architecture/ADMIN_HEALTH.md): the private admin site.
                            HStack(spacing: 2) {
                                Link(destination: OperationsDashboard.url(roles: model.operatorRoles)) {
                                    Label("Operations dashboard", systemImage: "chart.xyaxis.line")
                                }.accessibilityIdentifier("settings.operations")
                                InfoButton(text: "People, use, reliability and spending, on the private admin site. Sign in there once with your password and authenticator.")
                            }
                            .listRowBackground(Color.adminRow)
                        }
                        #if INTERNAL
                        SessionCaptureSettings().listRowBackground(Color.adminRow)
                        #endif
                        Button("Open reader sample") { model.openSample() }.listRowBackground(Color.adminRow)
                    } header: { Text("Admin") }
                }
            }
            .readableScrollColumn(width: width)
            .tabBarSpace(color: .chromeGroupedBackground)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                // On the Form: a sheet attached inside a Form row doesn't present reliably.
                .sheet(isPresented: $showDeleteAccount) { DeleteAccountView(model: model).macSheetKeys() }
                .onChange(of: model.readerSessionID) { _, _ in showDeleteAccount = false }
                .task(id: model.isSignedIn) { if model.isSignedIn { await model.refreshCreditBalance(); await model.refreshStoreSummary() } }
                .task { await model.refreshKeptExplanations() }
                // Its own task: a slow balance or store answer never holds the operator row back.
                .task(id: model.isSignedIn) { if model.isSignedIn { await model.refreshOperatorRoles() } }
                .toolbar { if let dismissSettings { ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismissSettings) } } }
        }
        // As a sheet (iPad, Mac) the window's own dimming sits under it.
        .modifier(SheetInfoDimming(enabled: dismissSettings != nil))
    }

    /// Admin and test tools: operators (the owner, support) and internal builds.
    private var showsAdmin: Bool {
        #if INTERNAL
        return true
        #else
        return !model.operatorRoles.isEmpty
        #endif
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

private struct SheetInfoDimming: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { if enabled { content.infoBubbleDimming() } else { content } }
}

/// The admin site's address for an operator: the owner lands on Health, support on Support.
enum OperationsDashboard {
    static func url(roles: [String]) -> URL {
        URL(string: roles.contains("owner") ? "https://admin.gradstep.ai/#health/30" : "https://admin.gradstep.ai/#support")!
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Private conversations and snippets are encrypted with keys held on your devices. An approved device or your recovery code is needed to restore them.")
            } header: { Text("Your snippets and conversations") }
            Section {
                Text("AI answers send your question, any selected passage, earlier messages in that conversation and, for paper chats, the paper’s text and the image of any figure or table you ask about through OpenRouter to Google Vertex (Gemini and Claude) or DeepInfra (DeepSeek), according to Answer options. A random account ID accompanies requests for cost accounting. Claude through OpenRouter writes the chat’s title and suggested questions. The model may search the web for some questions; those searches go to Tavily, a search service.")
            } header: { Text("AI answers") }
            // Owner, build 57: "We need more in here about terms of service and how we use arXiv articles and how we abide
            // by arXiv's terms" (docs/architecture/ARXIV_DEVICE_ONLY.md).
            Section {
                Text("Papers open from the official web version or PDF that arXiv publishes. Your device downloads them directly from arXiv when you open a paper, and prepares them for reading on the device, for you alone. A PDF you keep is stored encrypted on that device.")
                Text("Your device also asks arXiv when you search for papers. Gradstep’s servers never contact arXiv and keep no copies of papers; the Feed’s list of new papers comes from DataCite, which publishes arXiv’s records.")
                Text("Requests to arXiv are spaced out, name Gradstep, and stop for a day if arXiv asks this device to slow down, as arXiv’s API Terms of Use require. Each paper stays under its authors’ license, with a link back to arXiv.")
                Link("arXiv API Terms of Use", destination: URL(string: "https://info.arxiv.org/help/api/tou.html")!)
                Text(ArxivAcknowledgement.statement).foregroundStyle(.secondary)
            } header: { Text("Papers and arXiv") }
            Section {
                Text("A report you send, with its screenshot and notes, goes to Gradstep’s support so we can fix the problem, and is kept until you delete your account.")
            } header: { Text("Reports") }
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
                    NavigationLink(saved.diagram.title) {
                        DiagramDetail(diagram: saved.diagram).environment(\.figureImage) { manifest, paths in model.figureImage(manifest: manifest, paths: paths) }
                            .environment(\.figurePartCrops) { stored in model.figurePartCrops(stored) }
                    }
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
                        Text("Your private conversations and snippets are encrypted. If you lose all approved devices and this code, we cannot recover that content.")
                    }
                }
                if model.needsRecovery {
                    Section("Recovery code") {
                        TextField("Paste your recovery code", text: $input, axis: .vertical).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .hiddenFromReports().textContentType(.password).accessibilityIdentifier("recovery.input")
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
                        // `.privacySensitive()` doesn't redact screenshots: in-app reports cover the code (build 75).
                        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                            .hiddenFromReports().accessibilityIdentifier("recovery.code")
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

/// Paper search results for the Library's "ML paper search" segment. Adding stays in
/// search and appears as a pending import in the library.
struct DiscoveryList: View {
    @Bindable var model: ReaderModel
    @State private var issue: String?
    var body: some View {
        switch model.discoveryState {
        case .idle:
            ContentUnavailableView("Search by title, author or topic", systemImage: "magnifyingglass",
                                   description: Text("Search ML papers by title, author, topic or arXiv ID, then add a paper to your library."))
                .accessibilityIdentifier("discover.idle")
        case .searching:
            VStack { Spacer(); ProgressView("Searching ML papers…"); Spacer() }.accessibilityIdentifier("discover.searching")
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
        HStack(alignment: .center, spacing: 12) {
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
                                enabled: model.canBeginImport, setup: model.discoverySetup(sourceID: result.sourceID),
                                open: { model.openLibraryPaper(sourceID: result.sourceID) }, showLibrary: { model.showLibrary() }) {
                adding = true; issue = nil
                Task {
                    do { try await model.addDiscovered(result) }
                    catch ReaderModel.LibraryAddError.alreadyInLibrary { issue = "“\(result.title)” is already in your library." }
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
        ("htmlparser2, Temml", "Prepare a paper's arXiv HTML for the reader on this device, and typeset formulas the on-device model reads. Each reading carries these notices.", "MIT License"),
        ("arXiv", "Papers' official HTML versions, downloaded by this device, and their metadata. Papers keep their authors' licenses; shared episodes are limited to CC BY and CC0 papers.", "arXiv API terms"),
        ("DataCite", "Paper details, ML paper search and the shared Feed: the records arXiv registers for its papers. Our servers never contact arXiv.", "CC0 data"),
    ]
    var body: some View {
        List {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0).font(.headline)
                    Text(item.1).font(.subheadline)
                    Text(item.2).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
            }
            Section { Text(ArxivAcknowledgement.statement).font(.footnote).foregroundStyle(.secondary) }
                .accessibilityIdentifier("acknowledgements.arxiv")
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
                    Label("Your library, conversations, snippets and diagrams, and the files of papers converted privately for you", systemImage: "books.vertical")
                    Label("Your support reports and screenshots", systemImage: "exclamationmark.bubble")
                    Label("This device’s copy; other devices are signed out and your recovery code stops working", systemImage: "iphone")
                }
                Section {
                    Text("Unused credits are forfeited. Records of credits, AI usage and which papers were converted for you are kept without your email or name, for accounting.")
                    Text("An App Store subscription isn’t cancelled by deleting your account; manage it in Settings › Apple Account › Subscriptions.")
                    Text("Your beta invitation remains valid. Signing in again creates a new account; your deleted library, conversations and credits won’t return.")
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
/// The library panel's own margins, or the readable column.
private struct PanelOrColumn: ViewModifier {
    let panel: Bool
    func body(content: Content) -> some View {
        if panel { content.padding(.horizontal, 12) } else { content.readableColumn() }
    }
}

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

/// One pill, Gemini's message box (chat redesign 2026-10-16): the question, and under it the model control, then
/// (while the keyboard is up on iPhone) a way to put it away, dictation and Send (or Stop) at the trailing edge.
/// Nothing beside the pill (owner, build 57: "We can't have the typing window awkwardly to the right side"); Answer
/// options are in the chat's ⋯ menu.
private struct ChatComposerBox: View {
    @Bindable var model: ReaderModel
    var focused: FocusState<Bool>.Binding
    let compact: Bool

    var body: some View {
        let keyboardUp = focused.wrappedValue && UIDevice.current.userInterfaceIdiom == .phone
        let prompt = model.chatStudying ? "Your answer" : model.generalChat ? "Ask anything" : "Ask anything about the paper"
        VStack(alignment: .leading, spacing: 2) {
            TextField(prompt, text: $model.chatInput, axis: .vertical)
                .focused(focused).accessibilityIdentifier("chat.composer")
                .onChange(of: model.chatComposerFocusRequest) { _, _ in _ = model.takeComposerFocusRequest(); focused.wrappedValue = true }
                .task {
                    if model.takeComposerFocusRequest() {
                        // Let the field mount, without imposing a fixed delay on every new chat destination.
                        await Task.yield()
                        if !Task.isCancelled { focused.wrappedValue = true }
                    }
                }
                .lineLimit(1...(compact ? 2 : 6)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 5)
            HStack(spacing: 4) {
                // One control for the model (build 69: the model button and an options slider both chose it); its
                // Choose model page also has the length, Use for new chats and About. Answer options stay in ⋯.
                AISelectionButton(model: model).padding(.leading, 14)
                Spacer(minLength: 0)
                if keyboardUp {
                    Button { focused.wrappedValue = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 38, height: 40).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss keyboard").accessibilityIdentifier("chat.dismissKeyboard")
                        .keyboardShortcut(.cancelAction)
                }
                ChatDictationButton(model: model)
                sendButton
            }
        }
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
                    // ⌘Return sends (Mac and an iPad keyboard); Return starts a new line (and input methods keep Return).
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.buttonStyle(.plain).padding(3)
    }

    private func send() {
        // Mac (⌘Return): the composer ends editing first, so it can't write the sent text back afterwards;
        // then it takes the focus again for the next question.
        guard Platform.isMac, focused.wrappedValue else { Task { await model.sendMessage() }; return }
        focused.wrappedValue = false
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            await model.sendMessage()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            focused.wrappedValue = true
        }
    }

    private var sendDisabled: Bool {
        model.isGenerating || model.isDiscardingDraft || (!model.generalChat && !model.canUsePaperChat) || !model.chatContextComplete
            || model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
