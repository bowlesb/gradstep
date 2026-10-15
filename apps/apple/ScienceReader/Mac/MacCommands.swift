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
struct GradstepCommands: Commands {
    @Bindable var model: ReaderModel
    @FocusedValue(\.paperMenuActions) private var paper

    static let privacyURL = URL(string: "https://gradstep.ai/privacy/")!

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.tab = .settings }.keyboardShortcut(",")
        }

        // File
        CommandGroup(replacing: .newItem) {
            Button("Add Paper…") { addPaper() }.keyboardShortcut("n")
            Button("New Chat") { newChat() }.keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.generalChat && !model.canUsePaperChat && model.wideMode != .chat)
        }

        // Edit
        // ⌘F finds in the paper while reading (as in any Mac document) and searches the library elsewhere;
        // ⌥⌘F always searches the library (as Mail and Notes do), ⇧⌘F searches arXiv.
        CommandGroup(after: .pasteboard) {
            Section {
                if findsInPaper {
                    Button("Find in Paper…") { ReaderWebView.paper?.showFind() }.keyboardShortcut("f")
                    Button("Find Next") { ReaderWebView.paper?.findNext(backwards: false) }.keyboardShortcut("g")
                    Button("Find Previous") { ReaderWebView.paper?.findNext(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("Search Library") { search(arXiv: false) }.keyboardShortcut("f", modifiers: [.command, .option])
                } else {
                    Button("Search Library") { search(arXiv: false) }.keyboardShortcut("f")
                }
                Button("Search arXiv") { search(arXiv: true) }.keyboardShortcut("f", modifiers: [.command, .shift])
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
                Button(model.readerChatHidden ? "Show Chat Beside Paper" : "Hide Chat Beside Paper") {
                    model.readerChatHidden.toggle()
                }.keyboardShortcut("h", modifiers: [.command, .control])
                    .disabled(model.wideMode != .reader || model.tab == .settings)
            }
            Section {
                Picker("Library As", selection: $model.libraryLayout) {
                    ForEach(LibraryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sort Library By", selection: Binding(get: { model.librarySort.field },
                                                             set: { model.librarySort = LibrarySearchSort(field: $0) })) {
                    ForEach(LibrarySearchSort.Field.allCases, id: \.self) { Text($0.label).tag($0) }
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
            Divider()
            Menu("Ask About Selection") {
                ForEach(Array(SelectionAction.allCases.enumerated()), id: \.offset) { index, action in
                    Button(action.menuTitle) { paper?.selection?(action) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
            }.disabled(paper?.selection == nil)
            Button("Ask About This Paper") { model.askAboutSelectedPaper() }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.selectedPaper == nil)
            // The paper's "…" menu, item for item (PaperView), so nothing on screen is missing from the menu bar.
            Button("Listen") { if let paper = model.selectedPaper { model.podcasts.listen(to: paper) } }
                .disabled(model.selectedPaper.map { !model.podcasts.canListen(to: $0) } ?? true)
            Button("Chats About This Paper") { if let paper = model.selectedPaper { model.openAllChats(paper: paper.id) } }
                .disabled(model.selectedPaper.map { (model.paperChatCounts[$0.id] ?? 0) == 0 } ?? true)
            Button("Edit Tags…") { if let paper = model.selectedPaper { model.editTags(for: paper) } }
                .disabled(model.selectedPaper.map(\.isSample) ?? true)
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
    private var findsInPaper: Bool { paper != nil && (model.wideMode == .reader || model.wideMode == .browse) && model.tab != .settings }

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
