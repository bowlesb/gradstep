import SwiftUI
import ScienceReaderCore

struct RootView: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 { wideLayout(width: geometry.size.width) }
            else {
                VStack(spacing: 0) {
                    destination(model.tab)
                    HStack(spacing: 0) {
                        ForEach(ReaderTab.allCases) { tab in
                            Button {
                                model.tab = tab
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
        }
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $model.showSignIn) { AuthenticationView(model: model) }
        .sheet(isPresented: $model.showRecovery) { RecoveryView(model: model).interactiveDismissDisabled() }
        .sheet(isPresented: $model.showAllChats) { HistoryView(model: model, diagrams: false) }
        .sheet(isPresented: $model.showDiagrams) { HistoryView(model: model, diagrams: true) }
        .sheet(isPresented: $model.showReport, onDismiss: {
            model.reportScreenshot = nil
            if model.showReportsAfterComposer { model.showReportsAfterComposer = false; model.showReports = true }
        }) { ReportComposer(model: model) }
        .sheet(isPresented: $model.showReports) { if let service = model.support { ReportsView(service: service) } }
        .alert("Science Reader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Use cloud AI in this session?", isPresented: $model.showCloudConsent, titleVisibility: .visible) {
            Button("Allow cloud processing") { model.cloudConsent = true; Task { await model.sendMessage() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Until you sign out, messages you send may include the selected paper text and conversation context for our AI service. Saved history is encrypted with your device-held keys. The provider can read requests while processing them and may retain them under its policy.")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.synchronize() } } }
    }

    @ViewBuilder private func destination(_ tab: ReaderTab) -> some View {
        switch tab {
        case .feed: FeedView(model: model)
        case .library: LibraryView(model: model)
        case .paper: PaperView(model: model)
        case .chat: ChatView(model: model)
        case .settings: SettingsView(model: model)
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
                if model.email == nil {
                    HStack {
                        Image(systemName: "lock.icloud")
                        Text("Sign in to sync your library").font(.subheadline)
                        Spacer()
                        Button("Sign in") { model.showSignIn = true }.font(.subheadline.weight(.semibold))
                    }.padding(14).background(Color.accentColor.opacity(0.06))
                }
                HStack {
                    Picker("Search", selection: $model.searchExternal) { Text("Library").tag(false); Text("arXiv").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 220)
                    Spacer()
                    Menu { Picker("Sort", selection: $model.librarySort) { Text("Recent").tag("Recent"); Text("Title").tag("Title") } } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Sort papers")
                }.padding(.horizontal, 16).padding(.vertical, 10)
                if model.filteredPapers.isEmpty {
                    ContentUnavailableView {
                        Label(model.searchExternal ? "Find papers" : "Your library", systemImage: model.searchExternal ? "magnifyingglass" : "books.vertical")
                    } description: {
                        Text(model.searchExternal ? "Search arXiv to add a paper." : "Add a paper to read and ask questions.")
                    } actions: {
                        Button("Open sample") { model.openSample() }.buttonStyle(.bordered).accessibilityIdentifier("sample.open")
                    }
                } else {
                    List(model.filteredPapers) { paper in
                        Button { model.select(paper) } label: { PaperRow(paper: paper, selected: model.selectedPaper?.id == paper.id) }
                            .buttonStyle(.plain).listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.libraryQuery, prompt: "Title, author, or topic")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All chats", systemImage: "bubble.left.and.bubble.right") { model.showAllChats = true }
                        Button("All diagrams", systemImage: "square.stack.3d.up") { model.showDiagrams = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { model.showImport = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add a paper") }
            }
            .sheet(isPresented: $model.showImport) { ImportPaperView(model: model) }
        }
    }
}

struct PaperRow: View {
    let paper: Paper
    var selected = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(paper.title).font(.headline).foregroundStyle(selected ? Color.accentColor : .primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if paper.fileURL != nil { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Available offline") }
            }
            Text(paper.authors).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            if !paper.abstract.isEmpty { Text(paper.abstract).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            HStack {
                if let year = paper.year { Text(String(year)).font(.caption2).foregroundStyle(.secondary) }
                ForEach(paper.keywords.prefix(3), id: \.self) { Text($0).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.08), in: Capsule()) }
            }
        }.accessibilityElement(children: .combine)
    }
}

struct FeedView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Research feed", systemImage: "dot.radiowaves.up.forward", description: Text("New research will appear here."))
                .navigationTitle("Feed").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ChatView: View {
    @Bindable var model: ReaderModel
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Context", selection: $model.generalChat) {
                    Text("Paper chat").tag(false)
                    Text("General chat").tag(true)
                }.pickerStyle(.segmented).padding(12)
                if !model.generalChat, let paper = model.selectedPaper {
                    Text(paper.title).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal).padding(.bottom, 10)
                }
                if model.chatBranches.count > 1 {
                    Picker("Conversation branch", selection: $model.activeBranchID) {
                        ForEach(model.chatBranches, id: \.head) { branch in
                            Text(String((branch.messages.last?.payload.text ?? "Continuation").prefix(60))).tag(Optional(branch.head))
                        }
                    }.pickerStyle(.menu).padding(.horizontal).accessibilityLabel("Conversation branch")
                }
                if !model.chatContextComplete {
                    Text("Sync to load the earlier messages in this conversation.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.chatMessages.isEmpty {
                            ContentUnavailableView(model.generalChat ? "Explore an idea" : "Ask about this paper", systemImage: "bubble.left.and.bubble.right", description: Text(model.generalChat ? "Ask a research question." : "Select a passage or ask a question."))
                        }
                        ForEach(model.chatMessages, id: \.id) { message in
                            HStack {
                                if message.payload.role == .user { Spacer(minLength: 30) }
                                Text(.init(message.payload.text ?? "")).font(.system(size: model.chatFontSize * bodySize / 17)).textSelection(.enabled)
                                    .padding(12).background(message.payload.role == .user ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                if message.payload.role != .user { Spacer(minLength: 30) }
                            }
                        }
                    }.padding()
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Ask a question…", text: $model.chatInput, axis: .vertical).lineLimit(1...6).padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    Button { Task { await model.sendMessage() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).frame(width: 44, height: 44) }
                        .disabled(model.isGenerating || !model.chatContextComplete || model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send message")
                }.padding(12)
                if model.isGenerating { ProgressView("Saving…").font(.caption).padding(.bottom, 5) }
                else { Text(model.syncStatus).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 5) }
            }
            .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { model.showAllChats = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Chat history") }
                ToolbarItem(placement: .topBarTrailing) { Button { model.newChat(general: model.generalChat) } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New chat") }
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: ReaderModel
    var dismissSettings: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = model.email {
                        Label(email, systemImage: "person.crop.circle"); LabeledContent("Sync", value: model.syncStatus)
                        Button("Sign out") { Task { await model.signOut() } }
                        Text("Encrypted pending work stays on this device for your next sign-in.").font(.footnote).foregroundStyle(.secondary)
                    }
                    else { Button("Sign in or create an account") { model.showSignIn = true } }
                    LabeledContent("Environment", value: "Private beta · staging")
                }
                Section("Reading") {
                    Picker("Appearance", selection: $model.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    VStack(alignment: .leading) { Text("Paper text size"); Slider(value: $model.paperFontSize, in: 14...26, step: 1) }.accessibilityElement(children: .combine)
                    VStack(alignment: .leading) { Text("Chat text size"); Slider(value: $model.chatFontSize, in: 14...24, step: 1) }.accessibilityElement(children: .combine)
                }
                Section("Your research") {
                    Button("All chats") { model.showAllChats = true }
                    Button("All diagrams") { model.showDiagrams = true }
                    Button("Sync now") { Task { await model.synchronize() } }.disabled(model.email == nil)
                }
                Section("Privacy") {
                    Text("Private conversations and notes are encrypted with keys held on your devices. An approved device or your recovery code is needed to restore them.").font(.footnote).foregroundStyle(.secondary)
                    Text("Cloud AI receives the context you send. Private PDF uploads and reports you submit are accessible to the services that process them.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Testing") {
                    Button("Report this screen", systemImage: "ladybug") { model.beginReport() }
                    Button("My reports", systemImage: "tray") { model.showReports = true }.disabled(model.support == nil)
                    LabeledContent("Version", value: "0.1 (1)")
                    Button("Open reader sample") { model.openSample() }
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
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
            let entities = model.privateState.entities(kind: diagrams ? .diagram : .conversation)
            List(entities, id: \.self) { id in
                if let event = model.privateState.revisions(for: id).first {
                    Button(event.payload.text ?? "Untitled") { model.openConversation(id); dismiss() }
                }
            }.overlay { if entities.isEmpty { ContentUnavailableView(diagrams ? "No diagrams yet" : "No conversations yet", systemImage: diagrams ? "square.stack.3d.up" : "bubble.left.and.bubble.right") } }
                .navigationTitle(diagrams ? "All diagrams" : "All chats").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct AuthenticationView: View {
    @Bindable var model: ReaderModel
    @State private var email = ""
    @State private var password = ""
    @State private var create = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(create ? .newPassword : .password)
                } footer: { if create { Text("Use at least 12 characters. We’ll send an email to confirm your account.") } }
                Section {
                    Button { Task { await model.authenticate(email: email, password: password, create: create) } } label: {
                        HStack { Text(create ? "Create account" : "Sign in"); Spacer(); if model.isBusy { ProgressView() } }
                    }.disabled(model.isBusy || email.isEmpty || password.isEmpty || !model.configured)
                    Toggle("Create a new account", isOn: $create)
                }
                if !model.configured { Text("Cloud account setup is in progress for this development build. The offline reader sample is available.").foregroundStyle(.secondary).font(.footnote) }
            }.navigationTitle("Science Reader").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
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
                    Text(model.needsRecovery ? "Restore your private library" : "Save your recovery code").font(.title2.weight(.semibold))
                    Text("Your private conversations and notes are encrypted. If you lose all approved devices and this code, we cannot recover that content.")
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
                if model.isBusy { ProgressView() }
            }.navigationTitle("Private library").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ImportPaperView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Paper link") {
                    TextField("https://arxiv.org/abs/…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("New conversions show their maximum credit cost before processing. Eligible existing conversions are reused.").font(.footnote).foregroundStyle(.secondary)
                    Button("Continue") { model.error = "Paper import is waiting for the deployed processing service." }.disabled(link.isEmpty)
                }
                Section { Button("Open offline reader sample") { model.openSample(); dismiss() } }
            }.navigationTitle("Add a paper").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}
