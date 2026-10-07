import SwiftUI
import ScienceReaderCore

/// Add a paper (Library's +): an arXiv ID or link is queued on this device as before; a DOI or any
/// other link is identified by the server, which queues the paper or says what to do next.
/// docs/architecture/PDF_UPLOADS.md
struct ImportPaperView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var saving = false
    @State private var issue: String?
    @State private var outcome: AddOutcome?

    private var canAdd: Bool {
        #if DEBUG && FIXTURE_HOST
        if AddPaperFixture.isEnabled { return true }
        #endif
        return model.canBeginImport
    }
    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        issue = nil; outcome = nil
        switch AddInput(input) {
        case .empty: return
        case .arxiv:
            saving = true
            Task {
                defer { saving = false }
                do { try await model.importPaper(input); dismiss() }
                catch is CancellationError { }
                catch is ArxivReferenceError { issue = "Enter a valid arXiv link or paper ID." }
                catch LibraryCommandError.targetBusy { issue = "This paper already has a pending change." }
                catch { issue = "Couldn’t save this import. Your link is still here." }
            }
        case .lookup(let query):
            saving = true
            Task {
                defer { saving = false }
                guard let result = await model.addPaperOutcome(query) else { return }
                // The input may have changed while the server looked it up.
                guard AddInput(input) == .lookup(query) else { return }
                if result.finished { dismiss() } else { outcome = result }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("arXiv ID, DOI or link", text: $input).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("import.reference")
                        .disabled(saving)
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Paper link") } footer: {
                    Text("An arXiv ID, a DOI, or a link to a paper’s page or PDF.")
                }
                if saving, case .lookup = AddInput(input) {
                    Section { Label("Looking up the paper…", systemImage: "magnifyingglass").foregroundStyle(.secondary) }
                }
                if let outcome { outcomeSection(outcome) }
                if model.librarySignInRequired && !canAdd {
                    Section {
                        Text("Sign in to add papers to your library.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in") { dismiss(); model.openSignIn() }
                    }
                } else if !model.canChangeLibrary && !canAdd {
                    Section { Text("Finish setting up this device to add papers.").font(.footnote).foregroundStyle(.secondary) }
                } else if !model.libraryHasSnapshot && !canAdd {
                    Section {
                        Text("Refresh your library before adding a paper.").font(.footnote).foregroundStyle(.secondary)
                        Button("Refresh library") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing)
                    }
                }
            }.navigationTitle("Add a paper").navigationBarTitleDisplayMode(.inline)
                .onChange(of: input) { _, _ in outcome = nil; issue = nil }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving).macBarButton() }
                    // Design audit 2: a task sheet confirms in the top bar.
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Add") { add() }
                                .disabled(trimmed.isEmpty || !canAdd)
                                .accessibilityIdentifier("import.add")
                        }
                    }
                }
                .onSubmit { if !trimmed.isEmpty && canAdd { add() } }
                .interactiveDismissDisabled(saving)
                .macSheetKeys(enabled: !saving)
        }
    }

    @ViewBuilder private func outcomeSection(_ outcome: AddOutcome) -> some View {
        Section {
            Text(outcome.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add.outcome")
        }
    }
}
