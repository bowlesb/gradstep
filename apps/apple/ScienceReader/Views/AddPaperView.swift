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
    /// The PDF picker, and what a chosen file attaches to.
    @State private var picking: (target: PDFUploadTarget, title: String?)?
    @State private var dropTargeted = false

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
                catch ReaderModel.LibraryAddError.alreadyInLibrary {
                    // Open the paper that is already there instead of adding it twice (build 75).
                    if let source = try? ArxivReference(input).sourceID, model.papers.contains(where: { $0.sourceID == source && !$0.isSample }) {
                        dismiss(); model.openLibraryPaper(sourceID: source)
                    } else { issue = "Already in your library. It’s still being added." }
                }
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
                if canAdd {
                    Section {
                        Button { choosePDF(target: .newPaper, title: nil) } label: {
                            Label("Choose a PDF…", systemImage: "doc.badge.plus")
                        }.disabled(saving).accessibilityIdentifier("add.choosePDF")
                    } header: { Text("PDF file") } footer: {
                        Text(Platform.isLargeScreen ? "Or drop a PDF here. It stays on this device."
                             : "From Files. It stays on this device.")
                    }
                }
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
                // A link shared to Gradstep (Share › Gradstep): looked up as if typed here.
                .task {
                    guard let link = model.uploads.sharedLink else { return }
                    model.uploads.sharedLink = nil
                    input = link
                    add()
                }
                .fileImporter(isPresented: Binding(get: { picking != nil && !PDFUploadPresenter.fixturePicks }, set: { if !$0 { picking = nil } }),
                              allowedContentTypes: [.pdf]) { result in
                    guard let request = picking else { return }
                    picking = nil
                    if case .success(let url) = result { upload(url, target: request.target, title: request.title) }
                }
                .onDrop(of: [.pdf], isTargeted: $dropTargeted) { providers in
                    guard canAdd else { return false }
                    Task {
                        let urls = await PDFUploadIntake.loadDropped(providers)
                        guard let url = urls.first else { return }
                        upload(url, target: .newPaper, title: nil)
                    }
                    return true
                }
                .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
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
            ForEach(outcome.steps, id: \.self) { step in
                switch step {
                case .uploadPDF(let target, let title):
                    Button { choosePDF(target: target, title: title) } label: { Label(step.title, systemImage: "doc.badge.plus") }
                        .disabled(saving).accessibilityIdentifier(step.identifier)
                case .downloadOnDevice(let link, let target, let title):
                    Button {
                        // Runs on in the Library (progress there); the sheet's work is done.
                        Task { await model.uploads.downloadOnDevice(links: [link], title: title, target: target) }
                        dismiss()
                    } label: { Label(step.title, systemImage: "arrow.down.circle") }
                        .disabled(saving || !model.uploads.isActive).accessibilityIdentifier(step.identifier)
                }
            }
        }
    }

    private func choosePDF(target: PDFUploadTarget, title: String?) {
        issue = nil
        #if DEBUG && FIXTURE_HOST
        // UI fixtures can't drive the system picker: they pick the sample PDF.
        if AddPaperFixture.isEnabled, let url = try? AddPaperFixture.samplePDF() { upload(url, target: target, title: title); return }
        #endif
        picking = (target, title)
    }

    /// Queues the PDF (checked and copied first); the Library shows it from here, so the sheet closes.
    private func upload(_ url: URL, target: PDFUploadTarget, title: String?) {
        saving = true
        Task {
            defer { saving = false }
            if let problem = await PDFUploadIntake.add(url, target: target, title: title, model: model) { issue = problem } else { dismiss() }
        }
    }
}
