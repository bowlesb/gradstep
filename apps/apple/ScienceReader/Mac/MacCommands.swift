import ScienceReaderCore
import SwiftUI

/// What the open paper offers the menu bar (published by PaperView). nil members are unavailable now.
struct PaperMenuActions {
    var contents: (() -> Void)?
    /// Back to the reading position after following a citation.
    var back: (() -> Void)?
    /// Where Back goes, as the button on screen says it ("Back to 3 Method"); and the X beside it.
    var backTitle: String = "Back to Reading Position"
    var dismissBack: (() -> Void)? = nil
    /// Runs a selection action on the text selected in the paper.
    var selection: ((SelectionAction) -> Void)?
    /// The open paper's figure gallery; unavailable for a paper without figures.
    var figures: (() -> Void)? = nil
    /// Notes (NOTES_AND_SNIPPETS.md): draw a box on the page, or keep the selected text as a quotation.
    var drawSnippet: (() -> Void)? = nil
    var addSelectionToNote: (() -> Void)? = nil
    /// The paper's "…" › Reader version details (an arXiv HTML reading only).
    var readerVersion: (() -> Void)? = nil
}

private struct PaperMenuActionsKey: FocusedValueKey { typealias Value = PaperMenuActions }

extension FocusedValues {
    var paperMenuActions: PaperMenuActions? {
        get { self[PaperMenuActionsKey.self] }
        set { self[PaperMenuActionsKey.self] = newValue }
    }
}

extension View {
    /// Mac: offers the paper's actions to the menu bar (Paper menu). No effect on iPhone and iPad.
    @ViewBuilder func macPaperMenu(_ actions: PaperMenuActions) -> some View {
        #if targetEnvironment(macCatalyst)
        focusedSceneValue(\.paperMenuActions, actions)
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// The Mac menu bar. It mirrors each screen's "…" options menu (docs/DESIGN.md) and the header buttons,
/// so every action has one place on screen and one in the menus; nothing here is Mac-only behavior.
/// (Not attached on iPad yet; see ScienceReaderApp.)
struct GradstepCommands: Commands {
    @Bindable var model: ReaderModel
    @FocusedValue(\.paperMenuActions) private var paper

    static let privacyURL = URL(string: "https://gradstep.ai/privacy/")!

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.tab = .settings }.keyboardShortcut(",")
        }

        // File
        // After, not replacing: the replaced New group never reached the Mac's File menu (⌘N did nothing, found 2026-10-16).
        CommandGroup(after: .newItem) {
            Button("Add Paper…") { addPaper() }.keyboardShortcut("n")
            Button("New Chat") { newChat() }.keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.generalChat && !model.canUsePaperChat && model.wideMode != .chat)
        }

        // Edit
        // ⌘F finds in the paper while reading (as in any Mac document) and searches the library elsewhere;
        // ⌥⌘F always searches the library (as Mail and Notes do), ⇧⌘F is ML paper search.
        CommandGroup(after: .pasteboard) {
            Section {
                if findsInPaper {
                    // The paper view opens it, with its own checks (a readable paper, the selection cleared).
                    Button("Find in Paper…") { MacCommandRequests.shared.findInPaper = UUID() }.keyboardShortcut("f")
                    Button("Find Next") { ReaderWebView.paper?.findNext(backwards: false) }.keyboardShortcut("g")
                    Button("Find Previous") { ReaderWebView.paper?.findNext(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("Search Library") { search(arXiv: false) }.keyboardShortcut("f", modifiers: [.command, .option])
                } else {
                    Button("Search Library") { search(arXiv: false) }.keyboardShortcut("f")
                }
                Button("Search ML Papers") { search(arXiv: true) }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        // View
        CommandGroup(before: .toolbar) {
            Section {
                ForEach(Array(WideMode.allCases.enumerated()), id: \.offset) { index, mode in
                    Toggle(mode.rawValue, isOn: Binding(get: { model.wideMode == mode && model.tab != .settings },
                                                        set: { _ in model.showWideMode(mode) }))
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Button(model.wideMode == .browse ? "Hide Library Beside Paper" : "Show Library Beside Paper") {
                    model.showWideMode(model.wideMode == .browse ? .reader : .browse)
                }.keyboardShortcut("s", modifiers: [.command, .control])
                // In reading mode the chat slides over the paper instead (READING_MODE.md).
                Button(model.readingMode ? (model.readingChatShown ? "Hide Chat" : "Show Chat Over Paper")
                       : model.readerChatHidden ? "Show Chat Beside Paper" : "Hide Chat Beside Paper") {
                    if model.readingMode { model.readingChatShown.toggle() } else { model.readerChatHidden.toggle() }
                }.keyboardShortcut("h", modifiers: [.command, .control])
                    .disabled(!model.readingMode && (model.wideMode != .reader || model.tab == .settings))
            }
            // Reading mode and the paper's line width (READING_MODE.md). ⇧⌘R as Safari's Reader; the system's Enter Full
            // Screen (⌃⌘F) stays as it is.
            Section {
                Button(model.readingMode ? "Exit Reading Mode" : "Enter Reading Mode") { model.toggleReadingMode() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.readingMode && !model.canEnterReadingMode)
                Menu("Line Width") {
                    ForEach(Array(ReaderLineWidth.allCases.enumerated()), id: \.offset) { index, width in
                        Toggle(width.menuTitle, isOn: Binding(get: { model.paperLineWidth == width }, set: { if $0 { model.paperLineWidth = width } }))
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
                    }
                }
            }
            Section {
                Picker("Library As", selection: $model.libraryLayout) {
                    ForEach(LibraryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // As the Library's "…" menu: catalogs first, and the List offers only the fields it shows.
                Picker("Catalog", selection: Binding(get: { model.currentCatalog.id }, set: { model.selectCatalog($0) })) {
                    ForEach(model.libraryCatalogs.catalogs) { Text($0.name).tag($0.id) }
                }
                Button("Manage Catalogs…") { model.showCatalogs = true }
                Picker("Sort Library By", selection: Binding(get: { model.librarySort.field },
                                                             set: { model.librarySort = LibrarySearchSort(field: $0) })) {
                    ForEach(LibrarySearchSort.Field.allCases.filter {
                        !$0.isTableOnly || model.libraryLayout == .table || model.librarySort.field == $0
                    }, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Filter Library", selection: $model.libraryFilter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Menu("Show in Library") {
                    Toggle("Abstracts", isOn: $model.showAbstracts).disabled(model.libraryLayout != .list)
                    Toggle("Topics", isOn: $model.showTopics).disabled(model.libraryLayout != .list)
                }
                Picker("Feed As", selection: $model.feedLayout) {
                    ForEach(FeedLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.feedLayout == .table {
                    Picker("Sort Feed By", selection: Binding(get: { model.feedSort.key }, set: { key in
                        model.feedSort = PaperTableSort(key: key, ascending: key.ascendingFirst)
                    })) {
                        ForEach(FeedSortKey.offered(personal: model.currentFeedSelection.isPersonal), id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Hide Papers in Your Library", isOn: $model.feedHidesLibrary)
            }
            Section {
                Button("Larger Paper Text") { model.paperFontSize = min(26, model.paperFontSize + 1) }
                    .keyboardShortcut("+").disabled(model.paperFontSize >= 26)
                Button("Smaller Paper Text") { model.paperFontSize = max(14, model.paperFontSize - 1) }
                    .keyboardShortcut("-").disabled(model.paperFontSize <= 14)
                Button("Actual Paper Text Size") { model.paperFontSize = 17 }.keyboardShortcut("0")
                Button("Larger Chat Text") { model.chatFontSize = min(26, model.chatFontSize + 1) }
                    .keyboardShortcut("+", modifiers: [.command, .option])
                Button("Smaller Chat Text") { model.chatFontSize = max(13, model.chatFontSize - 1) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
            }
            Section {
                Button(model.wideMode == .feed ? (model.podcasts.listenSelected ? "Check for New Episodes" : "Refresh Feed") : "Refresh Library") { refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.wideMode == .feed ? model.librarySignInRequired : (!model.isSignedIn || model.libraryRefreshing))
                Button("All Chats") { model.showAllChats = true }.keyboardShortcut("y", modifiers: [.command, .shift])
                Button("All Diagrams") { model.showDiagrams = true }
            }
        }

        CommandMenu("Paper") {
            Button("Table of Contents") { paper?.contents?() }
                .keyboardShortcut("t", modifiers: [.command, .option]).disabled(paper?.contents == nil)
            Button("Figures") { paper?.figures?() }.disabled(paper?.figures == nil)
            Button(paper?.back == nil ? "Back to Reading Position" : paper?.backTitle ?? "Back to Reading Position") { paper?.back?() }
                .keyboardShortcut("[").disabled(paper?.back == nil)
            Button("Dismiss Back") { paper?.dismissBack?() }.disabled(paper?.dismissBack == nil)
            // J / K in the paper do the same.
            Button("Next Section") { model.stepSection(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaper?.readerBundle == nil)
            Button("Previous Section") { model.stepSection(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaper?.readerBundle == nil)
            Divider()
            Menu("Ask About Selection") {
                ForEach(Array(SelectionAction.allCases.enumerated()), id: \.offset) { index, action in
                    Button(action.menuTitle) { paper?.selection?(action) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
            }.disabled(paper?.selection == nil)
            Button("Ask About This Paper") { model.askAboutSelectedPaper() }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.selectedPaper == nil)
            // Notes: no keyboard shortcut until the existing bindings are audited (NOTES_AND_SNIPPETS.md).
            Button("Draw Snippet") { paper?.drawSnippet?() }.disabled(paper?.drawSnippet == nil)
            Button("Save Selection as Snippet") { paper?.addSelectionToNote?() }.disabled(paper?.addSelectionToNote == nil)
            // The paper's "…" menu, item for item (PaperView), so nothing on screen is missing from the menu bar.
            Button("Listen") { if let paper = model.selectedPaper { model.podcasts.listen(to: paper) } }
                .disabled(model.selectedPaper.map { !model.podcasts.canListen(to: $0) } ?? true)
            Button("Find Similar Papers") { if let paper = model.selectedPaper { model.findSimilarPapers(paper) } }
                .disabled(model.selectedPaper == nil)
            // AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): 1 credit, added to the current catalog.
            Menu("Recommend Similar Papers") {
                Section(model.recommendationCreditNote) {
                    ForEach(RecommendRequestBody.counts, id: \.self) { count in
                        Button(count == 1 ? "Add 1 Paper" : "Add \(count) Papers") { if let paper = model.selectedPaper { model.recommendSimilar(paper, count: count) } }
                    }
                }
            }
            .disabled(model.selectedPaper.map { !model.canRecommend($0) } ?? true)
            Button("Chats About This Paper") { if let paper = model.selectedPaper { model.openAllChats(paper: paper.id, thisPaper: true) } }
                .disabled(model.selectedPaper.map { (model.paperChatCounts[$0.id] ?? 0) == 0 } ?? true)
            Button("Edit Tags…") { if let paper = model.selectedPaper { model.editTags(for: paper) } }
                .disabled(model.selectedPaper.map(\.isSample) ?? true)
            Button("Reader Version Details…") { paper?.readerVersion?() }.disabled(paper?.readerVersion == nil)
            if let paper = model.selectedPaper, model.deviceModelAvailable, model.hasDeviceModelPDF(paper) {
                Divider()
                if model.isModelReading(paper) {
                    Button("Show the HTML Reading") { model.showHTMLReading() }
                    Button("Read Again with the On-Device Model") { model.readWithDeviceModel(paper, again: true) }.disabled(model.deviceModelRun != nil)
                } else {
                    Button("Read with the On-Device Model") { model.readWithDeviceModel(paper) }.disabled(model.deviceModelRun != nil)
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Report This Screen…") { model.beginReport(afterMenu: true) }
            Button("My Reports") { model.showReports = true }.disabled(model.support == nil)
            Divider()
            Button("Privacy & Data") { UIApplication.shared.open(Self.privacyURL) }
        }
    }

    /// Both Reader and Browse show the paper; option-command-F always targets the library.
    private var findsInPaper: Bool {
        model.selectedPaper?.readerBundle != nil && (model.wideMode == .reader || model.wideMode == .browse) && model.tab != .settings
    }

    // The same rules as the Library's + button and the Chat's compose button.
    private func addPaper() {
        if model.wideMode != .library && model.wideMode != .browse { model.showWideMode(.library) }
        if model.tab == .settings { model.showWideMode(model.wideMode) }
        if model.librarySignInRequired { model.openSignIn() } else { model.showImport = true }
    }

    private func newChat() {
        if model.tab == .settings { model.showWideMode(model.wideMode) }
        if model.wideMode != .reader && model.wideMode != .chat { model.showWideMode(model.generalChat ? .chat : .reader) }
        model.newChat(general: model.generalChat)
    }

    private func search(arXiv: Bool) {
        if model.tab == .settings || (model.wideMode != .library && model.wideMode != .browse) { model.showWideMode(.library) }
        model.searchExternal = arXiv
        MacCommandRequests.shared.librarySearch = UUID()
    }

    private func refresh() {
        // On Listen, the episodes (as its "…" menu's Check for new episodes); the hidden feed is not what is shown.
        if model.wideMode == .feed { if model.podcasts.listenSelected { model.podcasts.loadCatalog() } else { model.loadFeed() } }
        else { Task { await model.refreshLibrary() } }
    }
}
#endif
