import ScienceReaderCore
import SwiftUI

// Add to note (docs/architecture/NOTES_AND_SNIPPETS.md "Add to note"): the actual crop first (the encoded image that will
// be saved), the destination (the last one used on this device preselected; recent notes and New note), an optional
// comment and one quiet source line. Save commits on this device, then returns to the paper with "Saved to <note> ·
// Open note"; it never waits for the network. A failed save keeps everything on screen and never says Saved.

extension View {
    /// Presents the composer for captures made here (`origin`): the paper, a figure page, or the local PDF reader. Each
    /// host presents its own, so the composer is never competing with the sheet the capture came from.
    func noteComposerHost(_ model: ReaderModel, origin: CapturedSnippet.Origin) -> some View {
        modifier(NoteComposerHost(model: model, origin: origin))
    }
}

private struct NoteComposerHost: ViewModifier {
    @Bindable var model: ReaderModel
    let origin: CapturedSnippet.Origin
    func body(content: Content) -> some View {
        content.slotSheet(item: Binding(get: { model.notes.composer.flatMap { $0.snippet?.origin == origin ? $0 : nil } },
                                    set: { if $0 == nil { model.notes.composer = nil } })) { request in
            if let snippet = request.snippet { NoteComposerView(model: model, snippet: snippet).macSheetKeys(enabled: false) }
        }
    }
}

struct NoteComposerView: View {
    @Bindable var model: ReaderModel
    let snippet: CapturedSnippet
    @SheetDismiss private var dismiss
    @State private var destination: NoteDestinationChoice = .new
    @State private var newTitle = ""
    @State private var comment = ""
    @State private var prepared: PreparedSnippet?
    @State private var preview: UIImage?
    @State private var preparing = true
    @State private var saving = false
    @State private var issue: String?
    @State private var confirmDiscard = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                    destinationPicker
                    commentField
                    sourceLine
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("composer.issue")
                    }
                    Text(model.syncIssue == nil ? "Saved on this device first, then synced, encrypted, with your approved devices."
                         : "Saved on this device first. Sync resumes when it can.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(DesignMetrics.margin)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save snippet").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }.macBarButton().accessibilityIdentifier("composer.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                        .disabled(!canSave).accessibilityIdentifier("composer.save")
                }
            }
            .confirmationDialog("Discard this snippet?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { close(endCapture: true) }
                Button("Keep editing", role: .cancel) {}
            } message: { Text("Your comment and the captured region won’t be saved.") }
        }
        .sheetDismissDisabled(!comment.isEmpty || saving)
        .task { await prepare() }
        .onAppear {
            let notes = model.notes.state.notes
            if let last = model.notes.destination, notes.contains(where: { $0.id == last }) { destination = .existing(last) }
            else if let first = notes.first { destination = .existing(first.id) }
            else { destination = .new; newTitle = "Quick snippets" }
        }
    }

    private var canSave: Bool {
        guard !saving, !preparing, prepared != nil else { return false }
        if case .new = destination { return NoteRecord.normalizedTitle(newTitle) != nil }
        return true
    }

    // MARK: Parts

    @ViewBuilder private var content: some View {
        switch snippet.kind {
        case .region:
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let preview {
                        Image(uiImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .accessibilityLabel("The snippet that will be saved")
                    } else {
                        Rectangle().fill(Color(uiColor: .secondarySystemBackground)).aspectRatio(1.6, contentMode: .fit)
                            .overlay { ProgressView() }
                    }
                }
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: .separator), lineWidth: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("composer.preview")
                if snippet.origin != .equation { Button { adjust() } label: { Label("Adjust crop", systemImage: "crop") }
                    .font(.subheadline).frame(minHeight: 36).accessibilityIdentifier("composer.adjust") }
            }
        case .quote:
            Text(snippet.quote ?? "").font(.system(.body, design: .serif)).lineLimit(10)
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("composer.quote")
        case .text: EmptyView()
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collection").font(.subheadline.weight(.semibold))
            Menu {
                ForEach(model.notes.state.notes.prefix(20)) { note in
                    Button { destination = .existing(note.id) } label: {
                        if destination == .existing(note.id) { Label(note.title, systemImage: "checkmark") } else { Text(note.title) }
                    }
                }
                Divider()
                Button { destination = .new; if newTitle.isEmpty { newTitle = model.notes.state.notes.isEmpty ? "Quick snippets" : "" }; titleFocused = true } label: {
                    Label("New collection", systemImage: "plus")
                }.accessibilityIdentifier("composer.destination.new")
            } label: {
                HStack {
                    Text(destinationTitle).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Collection, \(destinationTitle)").accessibilityIdentifier("composer.destination")
            if case .new = destination {
                TextField("Name your collection", text: $newTitle)
                    .textFieldStyle(.plain).focused($titleFocused)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("New collection name").accessibilityIdentifier("composer.newTitle")
            }
        }
    }

    private var destinationTitle: String {
        switch destination {
        case .existing(let id): model.notes.state.note(id)?.title ?? "Choose a collection"
        case .new: "New collection"
        }
    }

    private var commentField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your comment (optional)").font(.subheadline.weight(.semibold))
            TextField("What caught your attention?", text: $comment, axis: .vertical)
                .lineLimit(3...10).textFieldStyle(.plain)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Your comment (optional)").accessibilityIdentifier("composer.comment")
        }
    }

    @ViewBuilder private var sourceLine: some View {
        if let source = snippet.source {
            let place = [source.revision.map { "v\($0)" }, source.label ?? source.section, source.page.map { "Page \($0)" }].compactMap { $0 }
            Text(([source.title] + place + [snippet.capturedAt.formatted(date: .abbreviated, time: .shortened)]).joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                .accessibilityIdentifier("composer.source")
        }
    }

    // MARK: Actions

    /// Encodes and seals once; the preview is the encoded image itself, so what is shown is what is saved.
    private func prepare() async {
        guard prepared == nil else { return }
        preparing = true
        defer { preparing = false }
        do {
            let result = try await model.prepareSnippet(snippet)
            prepared = result
            if snippet.kind == .region, let image = snippet.image {
                preview = (try? await previewImage(result)) ?? UIImage(cgImage: image)
            }
        } catch {
            issue = (error as? LocalizedError)?.errorDescription ?? "This snippet couldn’t be prepared. Try drawing it again."
        }
    }

    private func previewImage(_ prepared: PreparedSnippet) async throws -> UIImage? {
        guard let media = prepared.media?.full, let blob = prepared.blobs.first(where: { $0.blobID == media.blobID }),
              let accountID = model.device?.accountID else { return nil }
        let data = try NoteBlobCrypto.open(blob.blob, media: media, accountID: accountID)
        return try SnippetImageEncoder.decode(data, media: media)
    }

    private func save() {
        guard let prepared, canSave else { return }
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do {
                let saved = try await model.saveSnippet(snippet, prepared: prepared, to: destination, newTitle: newTitle, comment: comment)
                let title = model.notes.state.note(saved.noteID)?.title ?? newTitle
                model.notes.notice = NoteSavedNotice(noteID: saved.noteID, entryID: saved.entryID, title: title,
                                                     waiting: model.syncIssue != nil || model.backend == nil, origin: snippet.origin)
                close(endCapture: true)
            } catch {
                issue = StorageSpace.message(for: error).map { $0 + " Your snippet and comment are still here." }
                    ?? "Couldn’t save on this device. " + ((error as? LocalizedError)?.errorDescription ?? "Your snippet and comment are still here.")
            }
        }
    }

    private func cancel() {
        if !comment.isEmpty { confirmDiscard = true } else { close(endCapture: true) }
    }

    /// Back to the box over the page, as it was.
    private func adjust() {
        model.notes.composer = nil
        dismiss()
    }

    private func close(endCapture: Bool) {
        if endCapture { model.notes.capturing = nil }
        model.notes.composer = nil
        dismiss()
    }
}
