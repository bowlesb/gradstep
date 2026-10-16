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
                group("Model", selection: Binding(get: { choice.model }, set: { var next = choice; next.model = $0; set(next) }),
                      options: models, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.model) ?? choice.model.detail, identifier: "model")
                group("Length", selection: Binding(get: { choice.length }, set: { var next = choice; next.length = $0; set(next) }),
                      options: ChatProfileChoice.Length.allCases, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.length) ?? choice.length.detail, identifier: "length")
            }
            // Without the server's table nothing can be chosen (Try again stays usable).
            .disabled(table == nil)
        }
    }

    @ViewBuilder private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.chatProfileTableFailed ? "Couldn’t load the answer options. Answers use Sonnet · Standard."
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
                    NavigationLink { AIChatOptionsView(model: model) } label: {
                        Label("About AI chat options", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                    }.accessibilityIdentifier("chat.profile.about")
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Answer options").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("chat.profile.done") }
            }
        }
        .task { model.refreshChatProfiles(force: model.chatProfileTableFailed) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Owner, build 57: "an option to set the current options as the default for chats".
    @ViewBuilder private var defaults: some View {
        let choice = model.chatProfile, table = model.chatProfileTable
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if ChatProfileText.summary(choice) == ChatProfileText.summary(model.chatDefaultProfile) {
                Text("New chats start with these.").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.profile.isDefault")
            } else {
                Text("New chats start with \(ChatProfileText.summary(model.chatDefaultProfile, table: table)).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Use for new chats") { model.chatDefaultProfile = choice }
                    .font(.footnote.weight(.semibold)).accessibilityIdentifier("chat.profile.makeDefault")
            }
        }
    }
}

/// Settings › AI chat options (and About AI chat options from a chat): the same model and length choices, setting what
/// new chats start with, then what each model is, who processes it and what a question usually costs.
struct AIChatOptionsView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        let table = model.chatProfileTable
        List {
            Section {
                ChatChoiceControls(model: model, mode: .defaults).padding(.vertical, 6)
            } header: { Text("New chats start with") } footer: {
                Text("Each chat can change these from its ⋯ menu › Answer options. How much the model thinks is chosen for each question: quickly for simple ones, more carefully for derivations and comparisons.")
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
                    Text("\(table?.detail(option) ?? option.detail). Questions go to \(option.processor) to be answered.")
                }
            }
            if let note = table?.note {
                Section { } footer: { Text("Credits per question. \(note)").accessibilityIdentifier("settings.aiChat.note") }
            }
        }
        .navigationTitle("AI chat options").navigationBarTitleDisplayMode(.inline)
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
