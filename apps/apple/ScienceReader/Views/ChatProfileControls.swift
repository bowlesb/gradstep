import SwiftUI
import ScienceReaderCore

// Answer options (chat redesign 2026-10-16, docs/architecture/CHAT.md; owner, build 57: "the user should set the length,
// and the effort level should be chosen intelligently"; "literally nothing else is needed on this UI"). The chat's ⋯ menu
// opens them: the model and the length, making them the default, and About AI chat options (the same page as Settings ›
// AI chat options, with the credit detail). The server chooses the effort for each question and enforces and prices
// every choice; these views only display its published table.

/// The model and length pickers, each with what the chosen option means. `chat` edits the visible chat's choice;
/// `defaults` edits what new chats start with.
struct ChatChoiceControls: View {
    enum Mode { case chat, defaults }
    @Bindable var model: ReaderModel
    let mode: Mode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var choice: ChatProfileChoice { mode == .chat ? model.chatProfile : model.chatDefaultProfile }
    private func set(_ value: ChatProfileChoice) {
        if mode == .chat { model.setChatProfile(value) } else { model.chatDefaultProfile = value }
    }
    private var table: ChatProfileTable? { model.chatProfileTable }
    /// DeepSeek only when the server's table lists it.
    private var models: [ChatProfileChoice.Model] { table?.offeredModels ?? [.haiku, .sonnet, .opus] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if table == nil { unavailable }
            Group {
                modelRow("Anthropic models", options: models.filter { [.haiku, .sonnet, .opus].contains($0) })
                modelRow("Other providers", options: models.filter { ![.haiku, .sonnet, .opus].contains($0) })
                Text(table?.detail(choice.model) ?? choice.model.detail).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.profile.model.detail")
                group("Length", selection: Binding(get: { choice.length }, set: { var next = choice; next.length = $0; set(next) }),
                      options: ChatProfileChoice.Length.allCases, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.length) ?? choice.length.detail, identifier: "length")
            }
            // Without the server's table nothing can be chosen (Try again stays usable).
            .disabled(table == nil)
        }
    }

    @ViewBuilder private func modelRow(_ title: String, options: [ChatProfileChoice.Model]) -> some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            var next = choice; next.model = option; set(next)
                        } label: {
                            Text(table?.label(option) ?? option.label).font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 38).contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(choice.model == option ? Color.primary : Color.secondary)
                        .background(choice.model == option ? Color(uiColor: .tertiarySystemGroupedBackground) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityAddTraits(choice.model == option ? .isSelected : [])
                        .accessibilityIdentifier("chat.profile.model.\(option.rawValue)")
                    }
                }.padding(3).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.chatProfileTableFailed ? "Couldn’t load cloud models. Try again to choose a model."
                 : "Loading the answer options…").font(.footnote).foregroundStyle(.secondary)
            if model.chatProfileTableFailed {
                Button("Try again") { model.refreshChatProfiles(force: true) }.font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("chat.profile.retry")
            }
        }
    }

    /// One choice: a segmented control (a menu at accessibility text sizes, where segments truncate), then what the
    /// chosen option means.
    private func group<Option: Hashable & RawRepresentable>(_ title: String, selection: Binding<Option>, options: [Option],
        label: @escaping (Option) -> String, detail: String, identifier: String) -> some View where Option.RawValue == String {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("chat.profile.\(identifier)")
            } else {
                Text(title).font(.subheadline.weight(.semibold))
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0).accessibilityIdentifier("chat.profile.\(identifier).\($0.rawValue)") }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("chat.profile.\(identifier)")
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.profile.\(identifier).detail")
        }
    }
}

/// The chat's Answer options (⋯ › Answer options…): model and length, Use for new chats, About AI chat options.
struct AnswerOptionsSheet: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ChatChoiceControls(model: model, mode: .chat)
                    defaults
                    NavigationLink { AIChatOptionsView(model: model).toolbar(.visible, for: .navigationBar) } label: {
                        Label("About AI chat options", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                    }.accessibilityIdentifier("chat.profile.about")
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            #if targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close").accessibilityIdentifier("chat.profile.done")
                }
            }
            #else
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .task { model.refreshChatProfiles(force: model.chatProfileTableFailed) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityAction(.escape) { dismiss() }
    }

    /// Owner, build 57: "an option to set the current options as the default for chats".
    @ViewBuilder private var defaults: some View {
        let choice = model.chatProfile, table = model.chatProfileTable
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            let unchanged = ChatProfileText.summary(choice) == ChatProfileText.summary(model.chatDefaultProfile)
            Text("New chats currently start with \(ChatProfileText.summary(model.chatDefaultProfile, table: table)).")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier(unchanged ? "chat.profile.isDefault" : "chat.profile.defaultNote")
            Button("Reset default settings") { model.chatDefaultProfile = choice }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(unchanged || table == nil ? Color.secondary : Color.accentColor)
                .disabled(unchanged || table == nil)
                .accessibilityHint("Uses the selected model and length for new chats")
                .accessibilityIdentifier("chat.profile.makeDefault")
        }
    }
}

/// About AI chat options (Settings › Default options for new chats › ⓘ, and the chat's Answer options): what each model
/// is, who processes a question asked with it, and what a question usually costs at each length. The choices themselves
/// live in Settings and in each chat's Answer options (owner, build 59).
struct AIChatOptionsView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        let table = model.chatProfileTable
        List {
            Section {
                Text("How much the model thinks is chosen for each question: quickly for simple ones, more carefully for derivations and comparisons. Change a chat’s model and length from its ⋯ menu › Answer options; new chats start with your defaults in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(table?.offeredModels ?? [.haiku, .sonnet, .opus], id: \.self) { option in
                Section {
                    ForEach(ChatProfileChoice.Length.allCases, id: \.self) { length in
                        LabeledContent(table?.label(length) ?? length.label,
                                       value: table?.estimate(model: option, length: length).map(ChatProfileText.estimate) ?? "—")
                            .monospacedDigit()
                            .accessibilityIdentifier("settings.aiChat.\(option.rawValue).\(length.rawValue)")
                    }
                } header: { Text(table?.label(option) ?? option.label) } footer: {
                    Text(table?.detail(option) ?? option.detail)
                }
            }
            if let note = table?.note {
                Section { } footer: { Text("Credits per question. \(note)").accessibilityIdentifier("settings.aiChat.note") }
            }
        }
        .navigationTitle("About AI chat options").navigationBarTitleDisplayMode(.inline)
        .task { model.refreshChatProfiles() }
        .tabBarSpace(color: .chromeGroupedBackground)
    }
}

/// Renaming a conversation: the alert with its field, shared by the chat title menu and All chats.
struct RenameConversationAlert: ViewModifier {
    @Bindable var model: ReaderModel
    @Binding var conversation: UUID?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("Rename chat", isPresented: Binding(get: { conversation != nil }, set: { if !$0 { conversation = nil } })) {
            TextField("Title", text: $name).accessibilityIdentifier("chat.rename.field")
            Button("Save") {
                if let id = conversation { let title = name; Task { await model.renameConversation(id, to: title) } }
                conversation = nil
            }.accessibilityIdentifier("chat.rename.save")
            Button("Cancel", role: .cancel) { conversation = nil }
        } message: {
            Text("Up to 80 characters.")
        }
        .onChange(of: conversation) { _, id in
            name = id.flatMap { id in model.conversationSummaries.first { $0.id == id } }.map { ChatTitle.display($0) } ?? ""
        }
    }
}

extension View {
    func renameConversationAlert(model: ReaderModel, conversation: Binding<UUID?>) -> some View {
        modifier(RenameConversationAlert(model: model, conversation: conversation))
    }
}
