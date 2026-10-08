import SwiftUI
import ScienceReaderCore

// Model, effort and length in the chat (owner request 2026-10-08: "chats should have the ability to customize the
// length and effort and model right there in the chat in a clear UX"). A compact control in the message box shows
// the chat's choice ("Sonnet · Low · Standard") and opens these choices with the server's credit estimate. The server
// enforces and prices every choice; this view only displays its published table.
// docs/architecture/CHAT.md#models-effort-and-length

/// The control in the message box. `compact` (little height: a keyboard in landscape) shows only its symbol.
struct ChatProfileButton: View {
    @Bindable var model: ReaderModel
    var compact = false
    @State private var showing = false

    var body: some View {
        let choice = model.chatProfile
        let summary = ChatProfileText.summary(choice, table: model.chatProfileTable)
        Button { model.refreshChatProfiles(force: model.chatProfileTableFailed); showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                if !compact {
                    Text(summary).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 10 : 11).frame(minHeight: 30)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer settings")
        .accessibilityValue(summary)
        .accessibilityHint("Model, effort and length for this chat")
        .accessibilityIdentifier("chat.profile")
        .popover(isPresented: $showing, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ChatProfilePicker(model: model, mode: .chat)
                .frame(idealWidth: 360, maxWidth: 420)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The choices: model, effort and length, each with what it means, then the credit estimate. `chat` edits the visible
/// chat's choice (and can make it the default); `defaults` edits Settings › Chat defaults.
struct ChatProfilePicker: View {
    enum Mode { case chat, defaults }
    @Bindable var model: ReaderModel
    let mode: Mode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    private var choice: ChatProfileChoice { mode == .chat ? model.chatProfile : model.chatDefaultProfile }
    private func set(_ value: ChatProfileChoice) {
        if mode == .chat { model.setChatProfile(value) } else { model.chatDefaultProfile = value }
    }
    private var table: ChatProfileTable? { model.chatProfileTable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .chat {
                    Text("Answers in this chat").font(.headline).accessibilityAddTraits(.isHeader)
                }
                if table == nil {
                    unavailable
                }
                group("Model", selection: Binding(get: { choice.model }, set: { var next = choice; next.model = $0; set(next) }),
                      options: ChatProfileChoice.Model.allCases, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.model) ?? choice.model.detail, identifier: "model")
                group("Effort", selection: Binding(get: { choice.effort }, set: { var next = choice; next.effort = $0; set(next) }),
                      options: ChatProfileChoice.Effort.allCases, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.effort) ?? choice.effort.detail, identifier: "effort")
                group("Length", selection: Binding(get: { choice.length }, set: { var next = choice; next.length = $0; set(next) }),
                      options: ChatProfileChoice.Length.allCases, label: { table?.label($0) ?? $0.label },
                      detail: table?.detail(choice.length) ?? choice.length.detail, identifier: "length")
                if let table {
                    VStack(alignment: .leading, spacing: 4) {
                        if let estimate = table.estimateText(choice) {
                            Text(estimate).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .accessibilityIdentifier("chat.profile.estimate")
                        } else {
                            Text("This choice isn’t available right now; answers use \(ChatProfileText.summary(table.defaultChoice, table: table)).")
                                .font(.subheadline).accessibilityIdentifier("chat.profile.estimate")
                        }
                        if let note = table.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
                if mode == .chat { defaults }
            }
            .padding(20)
            .disabled(table == nil)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.chatProfileTableFailed ? "Couldn’t load the answer choices. Answers use Sonnet · Low · Standard."
                 : "Loading the answer choices…").font(.footnote).foregroundStyle(.secondary)
            if model.chatProfileTableFailed {
                Button("Try again") { model.refreshChatProfiles(force: true) }.font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("chat.profile.retry")
            }
        }
    }

    @ViewBuilder private var defaults: some View {
        let isDefault = choice == model.chatDefaultProfile
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if isDefault {
                Text("New chats start with these (Settings › Chat defaults).").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("New chats start with \(ChatProfileText.summary(model.chatDefaultProfile, table: table)).")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Use for new chats") { model.chatDefaultProfile = choice }.accessibilityIdentifier("chat.profile.makeDefault")
                    Button("Reset") { set(model.chatDefaultProfile) }.accessibilityIdentifier("chat.profile.reset")
                }.font(.footnote.weight(.semibold))
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

/// Settings › Chat defaults: the model, effort and length new chats start with (this device).
struct ChatDefaultsView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        ChatProfilePicker(model: model, mode: .defaults)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("Each chat can change these with the control in its message box; a chat keeps its own choice.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Chat defaults").navigationBarTitleDisplayMode(.inline)
            .task { model.refreshChatProfiles() }
            .tabBarSpace(color: Color(uiColor: .systemBackground))
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
