import ScienceReaderCore
import SwiftUI
import UIKit

// Notes (docs/architecture/NOTES_AND_SNIPPETS.md "Notes and navigation"): a list of named notes (search, +, rename and
// delete with confirmation, entry count, last edited) and each note's stream of snippets, quotations and the reader's
// writing, oldest first. iPhone: the fifth tab; iPad and Mac: a destination with list and detail side by side.

struct NotesView: View {
    @Bindable var model: ReaderModel
    /// iPad and Mac: list and detail side by side.
    var wide = false
    /// The window's width (the two slots' widths).
    var width: CGFloat = 0
    @State private var renaming: NotesState.Note?
    @State private var deleting: NotesState.Note?
    @State private var creating = false
    @State private var name = ""
    @State private var issue: String?
    /// The Wide shape (WideShape.swift): one top row over the list and the collection.
    @Environment(\.wideBar) private var wideBar

    var body: some View {
        Group {
            switch model.notesAvailability {
            case .signedOut: unavailable(locked: false)
            case .locked: unavailable(locked: true)
            case .ready:
                if wide { wideBody } else { phoneBody }
            }
        }
        .alert("New collection", isPresented: $creating) {
            TextField("Collection name", text: $name).accessibilityIdentifier("notes.name")
            Button("Cancel", role: .cancel) {}
            Button("Create") { let title = name; Task { await create(title) } }
        } message: { Text("A collection can hold snippets from as many papers as you like.") }
        .alert("Rename collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { note in
            TextField("Collection name", text: $name).accessibilityIdentifier("notes.name")
            Button("Cancel", role: .cancel) {}
            Button("Save") { let title = name; Task { await rename(note.id, title) } }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "Delete collection?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible,
                            presenting: deleting) { note in
            Button("Delete collection", role: .destructive) { Task { await delete(note.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text("This removes the collection and its \(note.entries.count) \(note.entries.count == 1 ? "snippet" : "snippets") from your devices when they sync. Your papers stay in the Library.")
        }
        .alert("Couldn’t save on this device", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
        .environment(\.noteActions, NoteActions(newNote: { name = ""; creating = true },
                                                 rename: { note in
                                                     // Beside the list, the open collection's name is renamed where it shows.
                                                     if wide, model.notes.openNoteID == note.id {
                                                         Task { try? await Task.sleep(for: .milliseconds(350)); model.notes.renameRequest = note.id }
                                                     } else { name = note.title; renaming = note }
                                                 },
                                                 delete: { deleting = $0 }))
    }

    // MARK: Phone: list, then the note pushed

    private var phoneBody: some View {
        NavigationStack {
            NotesList(model: model, selection: nil)
                .navigationDestination(item: Bindable(model.notes).openNoteID) { id in
                    NoteDetailView(model: model, noteID: id)
                }
        }
    }

    // MARK: iPad and Mac: list and detail

    @ViewBuilder private var wideBody: some View {
        if wideBar {
            // Collections | Collection on the shared two-slot container, its divider draggable; each slot's own row.
            TwoSlotLayout(width: width, other: .left, arrangement: .snippets,
                          selection: model.notes.openNoteID.map(AnyHashable.init)) {
                VStack(spacing: 0) {
                    collectionRow
                    NavigationStack { detail }
                }
            } otherView: {
                VStack(spacing: 0) {
                    listRow
                    NavigationStack { NotesList(model: model, selection: model.notes.openNoteID) }
                }
            }
        } else { splitBody }
    }

    /// The list's share of the row: its search field (where the iPhone's sits), then New collection.
    private var listRow: some View {
        WideBar {
            WideSearchField { NotesSearchField(text: Bindable(model.notes).search) }
        } center: {
            EmptyView()
        } trailing: {
            Button { name = ""; creating = true } label: { HeaderButtonLabel(systemImage: "plus") }
                .buttonStyle(.plain).accessibilityLabel("New collection").accessibilityIdentifier("notes.new")
        }
    }

    /// The collection's row: its name, then one ⋯ for the list and the open collection (audit N14).
    private var collectionRow: some View {
        let note = model.notes.openNoteID.flatMap { model.notes.state.note($0) }
        return WideBar {
            if let note {
                CollectionTitleField(model: model, note: note, alignment: .natural).id(note.id)
            }
        } trailing: {
            NotesScreenMenu(model: model, note: note, glass: true)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.notes.openNoteID, model.notes.state.note(id) != nil {
            NoteDetailView(model: model, noteID: id, showsBack: false).id(id)
        } else if !(wideBar && model.notes.state.notes.isEmpty) {
            // (Wide with no collections: the list beside says it once, with New collection.)
            ContentUnavailableView {
                Label { Text(model.notes.state.notes.isEmpty ? "Your ideas, collected" : "Choose a collection") } icon: { Image(GradstepSymbol.notes) }
            } description: {
                Text(model.notes.state.notes.isEmpty ? "Capture a snippet while reading with Paper ⋯ › Draw snippet." : "Its snippets show here.")
            }
        }
    }

    /// The Mac: list and detail with their own bars (its places are in the window toolbar).
    private var splitBody: some View {
        HStack(spacing: 0) {
            NavigationStack { NotesList(model: model, selection: model.notes.openNoteID) }
                .frame(width: 340)
            Divider()
            NavigationStack { detail }
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Locked and signed out

    private func unavailable(locked: Bool) -> some View {
        VStack(spacing: 0) {
            if wideBar { collectionRow }
            unavailableStack(locked: locked)
        }
    }

    private func unavailableStack(locked: Bool) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label { Text(locked ? "Unlock snippets" : "Snippets") } icon: { Image(GradstepSymbol.notes) }
            } description: {
                Text(locked ? "Snippets are encrypted with this account’s keys. Approve this device or use your recovery code to open them here."
                     : "Sign in to keep encrypted snippets of what you read, on all your devices.")
            } actions: {
                Button { model.openSignIn() } label: { ProminentLabel(title: locked ? "Unlock snippets" : "Sign in") }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier(locked ? "notes.unlock" : "notes.signIn")
            }
            .navigationTitle("Snippets").navigationBarTitleDisplayMode(.inline)
            .navigationBarHiddenInWide(wideBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NotesScreenMenu(model: model, note: nil) } }
            .tabBarSpace()
        }
    }

    // MARK: Writes

    private func create(_ title: String) async {
        do { let id = try await model.createNote(title); model.notes.openNoteID = id }
        catch { issue = (error as? LocalizedError)?.errorDescription ?? "The collection couldn’t be saved." }
    }
    private func rename(_ id: UUID, _ title: String) async {
        do { try await model.renameNote(id, to: title) }
        catch { issue = (error as? LocalizedError)?.errorDescription ?? "The collection couldn’t be renamed." }
    }
    private func delete(_ id: UUID) async {
        do { try await model.deleteNote(id) }
        catch { issue = (error as? LocalizedError)?.errorDescription ?? "The collection couldn’t be deleted." }
    }
}

/// The list's and detail's shared actions (presented by NotesView, so both layouts use one set of dialogs).
struct NoteActions {
    var newNote: () -> Void = {}
    var rename: (NotesState.Note) -> Void = { _ in }
    var delete: (NotesState.Note) -> Void = { _ in }
}
private struct NoteActionsKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue = NoteActions() }
extension EnvironmentValues {
    var noteActions: NoteActions {
        get { self[NoteActionsKey.self] }
        set { self[NoteActionsKey.self] = newValue }
    }
}

/// A screen's ⋯ (DESIGN.md): its actions, then Report this screen, then Settings.
struct NotesScreenMenu: View {
    @Bindable var model: ReaderModel
    let note: NotesState.Note?
    /// The Wide row's round glass button (a system bar draws its own).
    var glass = false
    @Environment(\.noteActions) private var actions

    var body: some View {
        Menu {
            if let note {
                // View choices first (DESIGN.md "Screen options"): collapse every snippet to its one line, or open them all
                // (owner, 2026-10-22). Offered only when it would change something.
                if !note.entries.isEmpty {
                    let collapsed = model.notes.collapsed(in: note.id).intersection(note.entries.map(\.id)).count
                    Section {
                        if collapsed < note.entries.count {
                            MenuRow("Collapse all", systemImage: "rectangle.compress.vertical") { setAll(true, note) }
                                .accessibilityIdentifier("note.collapseAll")
                        }
                        if collapsed > 0 {
                            MenuRow("Expand all", systemImage: "rectangle.expand.vertical") { setAll(false, note) }
                                .accessibilityIdentifier("note.expandAll")
                        }
                    }
                }
                // The name is edited where it is shown (owner, TestFlight 91), once the menu has closed.
                MenuRow("Rename collection", systemImage: "pencil") {
                    Task { try? await Task.sleep(for: .milliseconds(350)); model.notes.renameRequest = note.id }
                }.accessibilityIdentifier("note.rename")
                Button(role: .destructive) { actions.delete(note) } label: { Label("Delete collection", systemImage: "trash") }
                    .accessibilityIdentifier("note.delete")
            } else if model.notesAvailability == .ready {
                MenuRow("New collection", systemImage: "plus") { actions.newNote() }.accessibilityIdentifier("notes.menu.new")
            }
            MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
            SettingsMenuSection(model: model)
        } label: {
            if glass { HeaderButtonLabel(systemImage: "ellipsis") } else { Image(systemName: "ellipsis") }
        }
            .modifier(PlainButtonIf(plain: glass))
            .accessibilityLabel(note == nil ? "Snippets options" : "Collection options")
            .accessibilityIdentifier(note == nil ? "notes.options" : "note.options")
    }

    /// One step, without animation (owner, TestFlight 91: the first Collapse all went "jaggedy… at multiple stages" with
    /// "this black thing at the top"). Animated, every card of the lazy stream changed height at once while scrolled
    /// part-way: cards never laid out arrived mid-animation and the shrinking content left the area above uncovered for a
    /// few frames. Now the stream changes once.
    private func setAll(_ collapsed: Bool, _ note: NotesState.Note) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.notes.setAllCollapsed(collapsed, in: note.id) }
    }
}

// MARK: - List

struct NotesList: View {
    @Bindable var model: ReaderModel
    /// The note shown beside the list (iPad and Mac), highlighted.
    let selection: UUID?
    @Environment(\.noteActions) private var actions
    @Environment(\.wideBar) private var wideBar

    /// A collection picked: it opens beside the list, and a list covering the window (iPad Wide) splits again, even when
    /// it is the one already open (owner, 2026-10-23).
    private func open(_ id: UUID) {
        // From a search, the collection opens at its first snippet that matched.
        model.notes.focusEntryID = model.notes.searchMatches?.first { $0.noteID == id }?.entryIDs.first
        model.notes.openNoteID = id
        SlotFractions.shared.uncover()
    }

    var body: some View {
        let notes = model.notes.shownNotes
        List(selection: Binding(get: { selection }, set: { if let id = $0 { open(id) } })) {
            if let status = statusLine {
                Label(status, systemImage: "icloud.and.arrow.up").font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden).accessibilityIdentifier("notes.status")
            }
            if model.notes.state.malformedCount > 0 || !model.notes.state.futureNoteIDs.isEmpty || model.notes.state.incompleteEntryCount > 0 {
                Text(problemLine).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                    .accessibilityIdentifier("notes.problems")
            }
            ForEach(notes) { note in
                // Each note is a card (owner, 2026-10-21: "each needs a very pleasant border around it, so it looks like
                // a bunch of cards"; DESIGN.md "Cards"), 10 pt apart, inside the 16 pt margins.
                Button { open(note.id) } label: { NoteRow(model: model, note: note).contentCard(selected: note.id == selection) }
                    .buttonStyle(.plain)
                    .tag(note.id)
                    .listRowInsets(EdgeInsets(top: 5, leading: DesignMetrics.margin, bottom: 5, trailing: DesignMetrics.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("notes.row.\(note.title)")
                    .contextMenu {
                        Button { actions.rename(note) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { actions.delete(note) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { actions.delete(note) } label: { Label("Delete", systemImage: "trash") }
                        Button { actions.rename(note) } label: { Label("Rename", systemImage: "pencil") }.tint(.accentColor)
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if notes.isEmpty {
                let searching = !model.notes.search.trimmingCharacters(in: .whitespaces).isEmpty
                ContentUnavailableView {
                    Label { Text(searching ? "No matching snippets" : "Your ideas, collected") } icon: {
                        searching ? Image(systemName: "magnifyingglass") : Image(GradstepSymbol.notes)
                    }
                } description: {
                    Text(searching ? NotesSearchField.coverage : "Capture your first snippet in Paper with ⋯ › Draw snippet.")
                } actions: {
                    if searching { Button("Clear search") { model.notes.search = "" } }
                    else { Button { actions.newNote() } label: { ProminentLabel(title: "New collection") }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("notes.empty.new") }
                }
            }
        }
        .modifier(NotesSearchable(enabled: !wideBar, text: Bindable(model.notes).search))
        .navigationTitle("Snippets").navigationBarTitleDisplayMode(.inline)
        .navigationBarHiddenInWide(wideBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { actions.newNote() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New collection").accessibilityIdentifier("notes.new")
            }
            ToolbarItem(placement: .topBarTrailing) { NotesScreenMenu(model: model, note: nil) }
        }
        .tabBarSpace()
    }

    private var statusLine: String? {
        let count = model.notes.pendingCount
        guard count > 0 else { return nil }
        return "Saved on this device · \(count) waiting to sync"
    }

    private var problemLine: String {
        var parts: [String] = []
        let future = model.notes.state.futureNoteIDs.count + model.notes.state.futureRecordCount
        if future > 0 { parts.append("Update Gradstep to see \(future == 1 ? "a collection" : "\(future) collections and snippets") made with a newer version.") }
        if model.notes.state.incompleteEntryCount > 0 { parts.append("Some entries are still arriving.") }
        if model.notes.state.malformedCount > 0 {
            parts.append("\(model.notes.state.malformedCount) \(model.notes.state.malformedCount == 1 ? "entry" : "entries") couldn’t be read; send a report so it can be fixed.")
        }
        return parts.joined(separator: " ")
    }
}

struct NoteRow: View {
    let model: ReaderModel
    let note: NotesState.Note
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(GradstepSymbol.notes).symbolRenderingMode(.palette).foregroundStyle(Color.accentColor, Color.gradstepAmber)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 44).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            // Two lines (owner, TestFlight 91: "You just need two lines there, the title and then the number of snippets…
            // I would honestly remove the date too"): no preview of the latest snippet, no papers, no date. Waiting syncs
            // are said once, above the list.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(note.title).font(.headline).lineLimit(2)
                    if note.hasConflict { Text("2 versions").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                }
                Text(NoteCollectionLine.detail(entryCount: note.entries.count)).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes.row.detail")
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The open collection's name, edited where it is shown (owner, TestFlight 91: "I should be able to just relabel it right
/// in place there"): the title in its bar (Tall, the Mac) or its slot's row (Wide) is a text field. A tap puts the caret
/// in it; Return or leaving the field saves; Escape, or an empty name, puts the name back. ⋯ › Rename collection focuses it.
/// A UIKit field, so Escape from a hardware keyboard is the field's own (SwiftUI's TextField ends editing on Escape, which
/// would save instead of restoring).
struct CollectionTitleField: View {
    @Bindable var model: ReaderModel
    let note: NotesState.Note
    var alignment: NSTextAlignment = .center
    @State private var issue: String?
    @State private var saving: String?

    var body: some View {
        InPlaceTextField(text: note.title, placeholder: "Collection name", identifier: "note.title", alignment: alignment,
                         focusRequest: model.notes.renameRequest == note.id,
                         focusRequestHandled: { model.notes.renameRequest = nil },
                         limit: NotesFormat.maximumTitleScalars, commit: commit)
            .frame(minHeight: 34)
            .alert("Couldn’t rename on this device", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
    }

    /// Returns the text the field shows afterwards.
    private func commit(_ text: String) -> String {
        guard let title = NoteRecord.normalizedTitle(text) else { return note.title }
        // Return and the focus leaving both arrive: one rename.
        guard title != note.title, title != saving else { return title }
        let id = note.id
        saving = title
        Task {
            defer { saving = nil }
            do { try await model.renameNote(id, to: title) }
            catch { issue = (error as? LocalizedError)?.errorDescription ?? "The collection couldn’t be renamed." }
        }
        return title
    }
}

/// A one-line UIKit text field for a name edited in place: the headline font, no border, Return and losing focus commit
/// (`commit` returns what to show), Escape restores the name it was given, typing stops at `limit` Unicode scalars.
struct InPlaceTextField: UIViewRepresentable {
    let text: String
    let placeholder: String
    var identifier = ""
    var alignment: NSTextAlignment = .center
    var focusRequest = false
    var focusRequestHandled: () -> Void = {}
    var limit = 80
    let commit: (String) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EscapableTextField {
        let field = EscapableTextField()
        field.font = UIFont.preferredFont(forTextStyle: .headline)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = alignment
        field.placeholder = placeholder
        field.returnKeyType = .done
        field.borderStyle = .none
        field.clearButtonMode = .never
        field.text = text
        field.accessibilityLabel = placeholder
        field.accessibilityHint = "Edit to rename the collection"
        field.accessibilityIdentifier = identifier
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.onEscape = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.restoring = true
            field.text = coordinator.parent.text
            field.resignFirstResponder()
            coordinator.restoring = false
        }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: EscapableTextField, context: Context) {
        context.coordinator.parent = self
        field.textAlignment = alignment
        if !field.isFirstResponder, field.text != text { field.text = text }
        if focusRequest {
            DispatchQueue.main.async {
                focusRequestHandled()
                field.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: InPlaceTextField
        var restoring = false
        init(_ parent: InPlaceTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard let value = field.text, value.unicodeScalars.count > parent.limit else { return }
            field.text = String(String.UnicodeScalarView(value.unicodeScalars.prefix(parent.limit)))
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return false
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            guard !restoring else { return }
            field.text = parent.commit(field.text ?? "")
        }
    }
}

/// Escape (a hardware keyboard) restores instead of ending editing with the typed text.
final class EscapableTextField: UITextField {
    var onEscape: () -> Void = {}

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    @objc private func escapePressed() { onEscape() }

    // Where the key command isn't consulted (some text-input paths deliver the press directly).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) { onEscape(); return }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - A note's stream

struct NoteDetailView: View {
    @Bindable var model: ReaderModel
    let noteID: UUID
    var showsBack = true
    @State private var writing: NoteTextRequest?
    @State private var zoomed: NotesState.Entry?
    @State private var details: NotesState.Entry?
    @State private var reviewing: NotesState.Entry?
    @State private var deletingEntry: NotesState.Entry?
    @State private var issue: String?
    @Environment(\.noteActions) private var actions
    @Environment(\.wideBar) private var wideBar

    var body: some View {
        if let note = model.notes.state.note(noteID) {
            stream(note)
        } else {
            ContentUnavailableView("This collection is no longer here", systemImage: "trash",
                                   description: Text("It may have been deleted on another device."))
        }
    }

    private func stream(_ note: NotesState.Note) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Wide: no bar of its own; the collection's name is in its slot's row (NotesView, owner 2026-10-23).
                    if note.hasConflict { conflictBanner(note).padding(.bottom, 16) }
                    if note.futureEntryCount > 0 {
                        StatusBanner(tone: .info, systemImage: "arrow.down.app", message: "Update Gradstep to see \(note.futureEntryCount) more \(note.futureEntryCount == 1 ? "snippet" : "snippets") in this collection.")
                            .padding(.bottom, 16)
                    }
                    if note.entries.isEmpty {
                        emptyNote.frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    ForEach(Array(note.entries.enumerated()), id: \.element.id) { index, entry in
                        // One child per entry: its day label with its card.
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || !Calendar.current.isDate(day(entry), inSameDayAs: day(note.entries[index - 1])) {
                                Text(day(entry).formatted(date: .abbreviated, time: .omitted)).font(.footnote.weight(.semibold))
                                    // Owner, build 78: close to its first entry (now a card; 2026-10-22).
                                    .foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 14).padding(.bottom, 6).padding(.leading, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            NoteEntryView(model: model, entry: entry, number: index + 1,
                                          edit: { writing = NoteTextRequest(noteID: note.id, entryID: entry.id, text: entry.record.comment,
                                                                             kind: entry.record.kind) },
                                          zoom: { zoomed = entry }, details: { details = entry }, review: { reviewing = entry },
                                          delete: { deletingEntry = entry })
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 16)
                .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
            }
            // Scrolling the stream ends editing the name in the bar (which saves it).
            .scrollDismissesKeyboard(.immediately)
            .onAppear { scrollToFocus(reader) }
            .onChange(of: model.notes.focusEntryID) { _, _ in scrollToFocus(reader) }
        }
        .navigationTitle(note.title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!showsBack)
        .navigationBarHiddenInWide(wideBar)
        .toolbar {
            // The name in the bar is edited in place (owner, TestFlight 91). Wide hides this bar: its row has the field.
            if !wideBar {
                ToolbarItem(placement: .principal) {
                    CollectionTitleField(model: model, note: note).frame(minWidth: 120, maxWidth: 420)
                }
            }
            // Owner, build 78: "Let’s stick with the comment option for now only": no separate writing between snippets.
            ToolbarItem(placement: .topBarTrailing) { NotesScreenMenu(model: model, note: note) }
        }
        .tabBarSpace()
        .slotSheet(item: $writing) { request in NoteTextSheet(model: model, request: request).macSheetKeys(enabled: false) }
        .fullScreenCover(item: $zoomed) { entry in SnippetZoomView(model: model, entry: entry) }
        .slotSheet(item: $details) { entry in NoteSourceSheet(model: model, entry: entry).macSheetKeys() }
        .slotSheet(item: $reviewing) { entry in NoteVersionsSheet(model: model, entry: entry).macSheetKeys() }
        .confirmationDialog("Delete this snippet?", isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }),
                            titleVisibility: .visible, presenting: deletingEntry) { entry in
            Button("Delete snippet", role: .destructive) {
                Task { do { try await model.deleteEntry(entry.id) } catch { issue = (error as? LocalizedError)?.errorDescription } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("This removes it and its comment from this collection when your devices sync.") }
        .alert("Couldn’t save on this device", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }

    private func day(_ entry: NotesState.Entry) -> Date { Date(timeIntervalSince1970: Double(entry.record.capturedAt) / 1000) }

    private func scrollToFocus(_ reader: ScrollViewProxy) {
        guard let focus = model.notes.focusEntryID else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            reader.scrollTo(focus, anchor: .top)
            model.notes.focusEntryID = nil
        }
    }

    private var emptyNote: some View {
        ContentUnavailableView {
            Label { Text("A place for your next idea") } icon: { Image(GradstepSymbol.notes) }
        } description: {
            Text("Collect a snippet while reading with Paper ⋯ › Draw snippet, or select text and choose Save snippet.")
        } actions: {
            if model.selectedPaper != nil {
                Button { model.showPaperPlace() } label: { ProminentLabel(title: "Open Paper") }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("note.empty.openPaper")
            }
        }
    }

    private func conflictBanner(_ note: NotesState.Note) -> some View {
        StatusBanner(tone: .problem, systemImage: "square.on.square", message: "2 versions of this collection’s name", actionsBelow: true) {
            ForEach(note.heads, id: \.eventID) { version in
                Button("Keep “\(version.record.title)”") { Task { try? await model.renameNote(note.id, to: version.record.title) } }
            }
        }
    }
}

/// Add text or Edit comment.
struct NoteTextRequest: Identifiable {
    let id = UUID()
    let noteID: UUID
    /// nil: a new text entry.
    let entryID: UUID?
    let text: String
    let kind: NoteEntryRecord.Kind
}

// MARK: - One entry

struct NoteEntryView: View {
    @Bindable var model: ReaderModel
    let entry: NotesState.Entry
    let number: Int
    let edit: () -> Void
    let zoom: () -> Void
    let details: () -> Void
    let review: () -> Void
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    // Owner, 2026-10-22: "having the ability to collapse individual snippets would be helpful (so you can just see the
    // date/times), also having a bit cleaner separation still between the cards with the actual snippet itself being a
    // slightly more clear 'box' in a card". Each entry is a card (DESIGN.md "Cards"); its crop or quotation sits in an
    // inner box; the chevron collapses it to one line, remembered on this device.
    private var collapsed: Bool { model.notes.isCollapsed(entry.id, in: entry.record.noteID) }

    var body: some View {
        Group {
            if collapsed { collapsedCard } else { expandedCard }
        }
        .contentCard()
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.card.\(number)")
    }

    private var time: String { Date(timeIntervalSince1970: Double(entry.record.capturedAt) / 1000).formatted(date: .omitted, time: .shortened) }

    private func toggle() {
        let next = !collapsed
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            model.notes.setCollapsed(next, entry: entry.id, in: entry.record.noteID)
        }
    }

    /// The chevron: 44 pt to tap, drawn small; its label says what a tap does, its value what the card is now.
    private var disclosure: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -14)
        .accessibilityLabel(collapsed ? "Expand snippet" : "Collapse snippet")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("entry.disclosure.\(number)")
    }

    private var collapsedCard: some View {
        // One line: time · short paper title · first words of the comment (wraps to three at accessibility sizes).
        HStack(alignment: .center, spacing: 0) {
            disclosure
            // A phone's width gets a shorter title so the comment's first words still fit.
            Text(NoteCollapsedLine.line(time: time, record: entry.record,
                                        titleLimit: sizeClass == .compact ? NoteCollapsedLine.compactTitleLimit : NoteCollapsedLine.titleLimit))
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Expands the snippet")
                .accessibilityIdentifier("entry.collapsed.\(number)")
            if entry.hasConflict {
                Button("2 versions", action: review).font(.footnote.weight(.semibold)).tint(.orange).padding(.leading, 6)
                    .accessibilityIdentifier("entry.review")
            }
            options
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 0 : -10)
    }

    private var expandedCard: some View {
        let record = entry.record
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                disclosure
                Text("\(time) · \(kindLabel)").font(.footnote).foregroundStyle(.secondary)
                if entry.hasConflict {
                    Button("2 versions · Review", action: review).font(.footnote.weight(.semibold)).tint(.orange).padding(.leading, 6)
                        .accessibilityIdentifier("entry.review")
                }
                Spacer(minLength: 0)
                options
            }
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 0 : -10)
            switch record.kind {
            case .region:
                if let media = record.media {
                    Button(action: zoom) { NoteImageView(model: model, media: media.thumb ?? media.full, full: media.full, maxHeight: 260) }
                        .buttonStyle(.plain)
                        .snippetBox()
                        .accessibilityLabel("Snippet \(number)\(record.source?.label.map { ", \($0)" } ?? ""). Opens full size.")
                        .accessibilityIdentifier("entry.image.\(number)")
                }
            case .quote:
                Text(record.quote ?? "").font(.system(.body, design: .serif)).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .snippetBox(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .accessibilityIdentifier("entry.quote.\(number)")
            case .text: EmptyView()
            }
            if !record.comment.isEmpty {
                Text(record.comment).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, record.kind == .text ? 0 : 12)
                    .overlay(alignment: .leading) {
                        if record.kind != .text { Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: 3).accessibilityHidden(true) }
                    }
                    .accessibilityLabel(record.kind == .text ? record.comment : "Your comment: \(record.comment)")
                    .accessibilityIdentifier("entry.comment.\(number)")
            } else if record.kind != .text {
                Button("Add a comment", action: edit).font(.subheadline).frame(minHeight: 32).accessibilityIdentifier("entry.addComment.\(number)")
            }
            if let source = record.source {
                Button(action: details) {
                    (Text(source.title).foregroundStyle(Color.accentColor) + Text(sourceDetail(source)).foregroundStyle(.secondary))
                        .font(.footnote).multilineTextAlignment(.leading).lineLimit(3)
                }
                .buttonStyle(.plain).accessibilityHint("Shows where this came from").accessibilityIdentifier("entry.source.\(number)")
            }
            if let sync = model.notes.sync(of: entry).label {
                Label(sync, systemImage: model.notes.sync(of: entry) == .waiting || model.notes.sync(of: entry) == .uploadingImage
                      ? "icloud.slash" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("entry.sync.\(number)")
            }
        }
    }

    private var options: some View {
        let record = entry.record
        return Menu {
            MenuRow(record.kind == .text ? "Edit text" : "Edit comment", systemImage: "pencil", action: edit)
                .accessibilityIdentifier("entry.edit")
            // Owner, 2026-10-21: a Chat option to talk about the snippet (nothing is sent until the reader asks).
            if record.kind != .text {
                MenuRow("Chat", systemImage: "bubble.left.and.text.bubble.right") { model.chatAboutNoteEntryLoadingImage(entry) }
                    .accessibilityIdentifier("entry.chat")
            }
            if record.source != nil {
                MenuRow("Open in paper", systemImage: "doc.text") { if !model.openNoteSource(record) { details() } }
                    .accessibilityIdentifier("entry.openInPaper")
                MenuRow("Source details", systemImage: "info.circle", action: details)
            }
            Button(role: .destructive, action: delete) { Label(record.kind == .text ? "Delete text" : "Delete snippet", systemImage: "trash") }
                .accessibilityIdentifier("entry.delete")
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .padding(.trailing, -10)
        .accessibilityLabel("Entry \(number) options").accessibilityIdentifier("entry.options.\(number)")
    }

    private var kindLabel: String {
        switch entry.record.kind { case .region: "Region snippet"; case .quote: "Text snippet"; case .text: "Your writing" }
    }

    private func sourceDetail(_ source: NoteSource) -> String {
        var parts: [String] = []
        if let revision = source.revision, source.kind != .document { parts.append("v\(revision)") }
        if let label = source.label { parts.append(label) } else if let section = source.section { parts.append(section) }
        if let page = source.page { parts.append("Page \(page)") }
        parts.append(Date(timeIntervalSince1970: Double(entry.record.capturedAt) / 1000).formatted(date: .abbreviated, time: .shortened))
        return " · " + parts.joined(separator: " · ")
    }
}

/// The snippet itself inside its card (owner, 2026-10-22: "the actual snippet itself being a slightly more clear 'box' in
/// a card"): the grouped tertiary fill (a step from the card's in both appearances), a 1 pt separator edge (opaque with
/// Increase Contrast), 10 pt continuous corners. Solid in every mode.
struct SnippetBox: ViewModifier {
    var padding = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(uiColor: .tertiarySystemGroupedBackground)))
            .overlay(shape.strokeBorder(Color(uiColor: contrast == .increased ? .opaqueSeparator : .separator), lineWidth: 1))
    }
}

extension View {
    func snippetBox(padding: EdgeInsets = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) -> some View {
        modifier(SnippetBox(padding: padding))
    }
}

/// A snippet's image: the thumbnail first, decrypted and checked on this device; a placeholder with Retry while it is
/// missing (never another crop).
struct NoteImageView: View {
    let model: ReaderModel
    let media: NoteMedia
    var full: NoteMedia? = nil
    var maxHeight: CGFloat = 260
    @State private var image: UIImage?
    @State private var failed: String?
    @State private var attempt = 0

    var body: some View {
        let ratio = CGFloat(media.width) / CGFloat(max(1, media.height))
        // The frame hugs the image (aspect-correct, at most `maxHeight` tall; a tall one opens full size on a tap).
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(ratio, contentMode: .fit)
            } else {
                Rectangle().fill(Color(uiColor: .secondarySystemBackground)).aspectRatio(ratio, contentMode: .fit)
                    .overlay {
                        if let failed {
                            VStack(spacing: 6) {
                                Label(failed, systemImage: "photo").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Retry") { self.failed = nil; attempt += 1 }.font(.footnote.weight(.semibold))
                                    .accessibilityIdentifier("entry.image.retry")
                            }.padding(8)
                        } else { ProgressView() }
                    }
                    .frame(minWidth: failed == nil ? nil : 220, minHeight: failed == nil ? nil : 120)
            }
        }
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: .separator), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(media.blobID.wire)/\(attempt)") {
            do { image = try await model.noteImage(media) }
            catch { failed = Self.message(error) }
        }
    }

    static func message(_ error: Error) -> String {
        switch error {
        case NoteAssetError.downloadLimit: "This month’s image downloads are used up. The snippet’s words are still here."
        case NoteAssetError.notFound: "This image isn’t available yet."
        case NoteAssetError.signInRequired: "Sign in again to download this image."
        case is NoteBlobCrypto.Failure: "This image didn’t pass its check, so it isn’t shown."
        default: "Image not downloaded."
        }
    }
}

// MARK: - Full size

struct SnippetZoomView: View {
    let model: ReaderModel
    let entry: NotesState.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                if let image { ZoomableImage(image: image).ignoresSafeArea(edges: .bottom).accessibilityIdentifier("zoom.image") }
                else if let failed { ContentUnavailableView(failed, systemImage: "photo") }
                else { ProgressView() }
            }
            .navigationTitle(entry.record.source?.label ?? "Snippet").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Chat about this snippet (owner, 2026-10-21), as a figure's Chat about Figure: a chat with it attached, nothing sent.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        let shown = image?.cgImage
                        dismiss()
                        if let shown { model.chatAboutNoteEntry(entry, image: shown) } else { model.chatAboutNoteEntryLoadingImage(entry) }
                    } label: { Text("Chat") }
                    .accessibilityHint("A chat about this snippet; nothing is sent until you ask.")
                    .accessibilityIdentifier("zoom.chat")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("zoom.done") }
            }
            .task {
                guard let media = entry.record.media?.full else { return }
                do { image = try await model.noteImage(media) } catch { failed = NoteImageView.message(error) }
            }
        }
        .macSheetKeys()
    }
}

/// Pinch and double-tap zoom over an image (UIScrollView), centered.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = true; view.accessibilityLabel = "Snippet image"
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        DispatchQueue.main.async { context.coordinator.layout(scroll) }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func layout(_ scroll: UIScrollView) {
            guard let imageView, scroll.zoomScale == 1 else { return }
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 3, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

// MARK: - Writing

struct NoteTextSheet: View {
    let model: ReaderModel
    let request: NoteTextRequest
    @SheetDismiss private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var issue: String?
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool

    private var isNew: Bool { request.entryID == nil }
    private var label: String { request.kind == .text ? "Your writing" : "Your comment" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 160)
                    .accessibilityLabel(label).accessibilityIdentifier("note.text")
                if !isNew {
                    Text("The original source and capture time stay with the snippet.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("note.text.issue") }
                Spacer()
            }
            .padding(DesignMetrics.margin)
            .navigationTitle(isNew ? "Add text" : (request.kind == .text ? "Edit text" : "Edit comment")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if text != request.text { confirmDiscard = true } else { dismiss() } }.macBarButton()
                        .accessibilityIdentifier("note.text.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Save" : "Done") { save() }.disabled(saving || (isNew && text.allSatisfy(\.isWhitespace)))
                        .accessibilityIdentifier("note.text.save")
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .onAppear { text = request.text; focused = true }
        .sheetDismissDisabled(text != request.text)
    }

    private func save() {
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do {
                if let entryID = request.entryID { try await model.editComment(entryID, comment: text) }
                else { model.notes.focusEntryID = try await model.addText(text, to: request.noteID) }
                dismiss()
            } catch {
                issue = StorageSpace.message(for: error).map { $0 + " Your text is still here." }
                    ?? "Couldn’t save on this device. " + ((error as? LocalizedError)?.errorDescription ?? "Your text is still here.")
            }
        }
    }
}

// MARK: - Source and versions

struct NoteSourceSheet: View {
    let model: ReaderModel
    let entry: NotesState.Entry
    @SheetDismiss private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let source = entry.record.source {
                    Section {
                        Text(source.title).font(.headline)
                        if !source.authors.isEmpty { Text(source.authors.prefix(6).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Section {
                        if let id = source.sourceID, source.kind != .document { LabeledContent("Version", value: id + (source.revision.map { "v\($0)" } ?? "")) }
                        if let label = source.label { LabeledContent("Item", value: label) }
                        if let section = source.section { LabeledContent("Section", value: section) }
                        if let page = source.page { LabeledContent("PDF page", value: "\(page)") }
                        LabeledContent("Captured", value: Date(timeIntervalSince1970: Double(entry.record.capturedAt) / 1000)
                            .formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Paper on this device", value: available ? "Yes" : "No")
                    } footer: {
                        Text(available ? "Open in paper returns to the captured passage when this copy of the paper has it."
                             : "Your snippet is still here. Add this exact paper version to your Library to open its source.")
                    }
                    if available {
                        Button("Open in paper") { dismiss(); _ = model.openNoteSource(entry.record) }.accessibilityIdentifier("source.open")
                    } else if let url = source.url.flatMap(URL.init(string:)) {
                        Link("View on arXiv", destination: url)
                    }
                }
            }
            .navigationTitle("Snippet details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var available: Bool {
        guard let source = entry.record.source else { return false }
        return model.papers.contains { paper in
            (source.membershipID != nil && paper.sourceMembership?.membershipID == source.membershipID)
                || (source.kind == .arxiv && paper.sourceID == source.sourceID)
                || (source.kind == .document && paper.id.wire == source.sourceID)
        }
    }
}

/// "2 versions · Review": both versions in full; keeping one writes a revision whose parents are both (no silent merge).
struct NoteVersionsSheet: View {
    let model: ReaderModel
    let entry: NotesState.Entry
    @SheetDismiss private var dismiss
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            List {
                Section { Text("This was edited on two devices before they synced. Keep the version you want; the other is replaced everywhere.")
                    .font(.footnote).foregroundStyle(.secondary) }
                ForEach(Array(entry.heads.enumerated()), id: \.element.eventID) { index, version in
                    Section(version.editedAt.map { "Version \(index + 1) · " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) }
                            ?? "Version \(index + 1)") {
                        Text(version.record.comment.isEmpty ? "No comment" : version.record.comment)
                        Button("Keep this version") {
                            Task {
                                do { try await model.keepVersion(entry.id, version: version.record); dismiss() }
                                catch { issue = (error as? LocalizedError)?.errorDescription }
                            }
                        }.accessibilityIdentifier("versions.keep.\(index + 1)")
                    }
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle("2 versions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The Snippets list's search drawer (Tall); Wide searches from the places capsule instead.
private struct NotesSearchable: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: NotesSearchField.prompt) }
        else { content }
    }
}

/// The Wide row's snippets search field.
struct NotesSearchField: View {
    /// What the search covers, in the field (owner, TestFlight 91: "What in the snippets does it actually search?").
    static let prompt = "Names, comments, text, papers"
    /// The same in full, when nothing matched.
    static let coverage = "Searches collection names, comments, quoted text, the words and equations in drawn snippets, and paper titles and authors. Words match from their start."
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(Self.prompt, text: $text).focused($focused).submitLabel(.search)
                .accessibilityIdentifier("notes.search")
        }
    }
}

/// The app's round glass buttons are plain buttons; a system bar draws its own.
struct PlainButtonIf: ViewModifier {
    let plain: Bool
    func body(content: Content) -> some View {
        if plain { content.buttonStyle(.plain) } else { content }
    }
}
