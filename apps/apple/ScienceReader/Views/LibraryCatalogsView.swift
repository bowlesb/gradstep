import SwiftUI
import ScienceReaderCore

private func catalogPaperCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "paper" : "papers")"
}

struct LibraryCatalogsView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var showName = false
    @State private var renameID: UUID?
    @State private var name = ""
    @State private var deleting: LibraryCatalog?
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            List {
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("catalog.issue") } }
                if !model.canManageCatalogs {
                    Section { Text("Sign in and unlock your library to manage catalogs.").foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(model.libraryCatalogs.catalogs) { catalog in
                        HStack {
                            Button {
                                model.selectCatalog(catalog.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(catalog.name).foregroundStyle(.primary)
                                        Text(catalogPaperCount(model.catalogCount(catalog.id)) +
                                             (catalog.id == model.libraryCatalogs.defaultID ? " · Default" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.currentCatalog.id == catalog.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(catalog.name)
                                .accessibilityValue(model.currentCatalog.id == catalog.id ? "Selected" : "")
                                .accessibilityIdentifier("catalog.select.\(catalog.id.wire)")
                            Menu {
                                Button("Rename", systemImage: "pencil") { renameID = catalog.id; name = catalog.name; showName = true }
                                if catalog.id != model.libraryCatalogs.defaultID {
                                    Button("Make default", systemImage: "star") { perform { try await model.makeDefaultCatalog(catalog.id) } }
                                }
                                Button("Delete catalog…", systemImage: "trash", role: .destructive) { deleting = catalog }
                            } label: { Image(systemName: "ellipsis").padding(10).contentShape(Rectangle()) }
                                .accessibilityLabel("Options for \(catalog.name)")
                                .disabled(!model.canManageCatalogs || model.catalogBusy)
                        }.disabled(model.catalogBusy)
                    }
                } footer: {
                    Text("Each paper belongs to one catalog. Your default opens when you start the app; new papers go into the catalog you’re viewing.")
                }
                Section {
                    Button("New catalog", systemImage: "plus") { renameID = nil; name = ""; showName = true }
                        .disabled(!model.canManageCatalogs || model.catalogBusy).accessibilityIdentifier("catalog.create")
                }
                if model.catalogBusy { ProgressView("Saving…") }
            }
            .navigationTitle("Catalogs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close catalogs").disabled(model.catalogBusy)
                }
            }
            .alert(renameID == nil ? "New catalog" : "Rename catalog", isPresented: $showName) {
                TextField("Catalog name", text: $name).accessibilityIdentifier("catalog.name")
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    let value = name, target = renameID
                    perform {
                        if let target { try await model.renameCatalog(target, name: value) }
                        else { _ = try await model.createCatalog(value) }
                    }
                }.disabled(LibraryCatalogBatch.normalizedName(name) == nil)
            }
            .sheet(item: $deleting) { catalog in LibraryCatalogDeletionView(model: model, catalog: catalog).macSheetKeys() }
            .interactiveDismissDisabled(model.catalogBusy)
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        let scope = model.catalogScope; issue = nil; model.catalogBusy = true
        Task {
            defer { if model.catalogScope == scope { model.catalogBusy = false } }
            do { try await action() }
            catch { if model.catalogScope == scope { issue = (error as? LibraryCatalogError)?.errorDescription ?? "Couldn’t save this catalog change. Try again." } }
        }
    }
}

private struct LibraryCatalogDeletionView: View {
    enum Disposition: String, CaseIterable { case existing, new, deletePapers }
    @Bindable var model: ReaderModel
    let catalog: LibraryCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var disposition: Disposition
    @State private var destination: UUID?
    @State private var name = ""
    @State private var issue: String?
    @State private var confirmDelete = false

    init(model: ReaderModel, catalog: LibraryCatalog) {
        self.model = model; self.catalog = catalog
        let other = model.libraryCatalogs.catalogs.first { $0.id != catalog.id }?.id
        _destination = State(initialValue: other)
        _disposition = State(initialValue: model.catalogCount(catalog.id) == 0 ? .deletePapers : other == nil ? .new : .existing)
    }
    private var others: [LibraryCatalog] { model.libraryCatalogs.catalogs.filter { $0.id != catalog.id } }
    private var valid: Bool {
        switch disposition {
        case .existing: destination.map { id in others.contains { $0.id == id } } == true
        case .new: LibraryCatalogBatch.normalizedName(name) != nil
        case .deletePapers: true
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(catalog.name) contains \(catalogPaperCount(model.catalogCount(catalog.id))).")
                    Picker("What happens to its papers?", selection: $disposition) {
                        if !others.isEmpty { Text("Move to another catalog").tag(Disposition.existing) }
                        Text("Move to a new catalog").tag(Disposition.new)
                        Text("Delete its papers").tag(Disposition.deletePapers)
                    }.pickerStyle(.inline)
                }
                if disposition == .existing {
                    Section("Move papers to") {
                        Picker("Catalog", selection: $destination) {
                            ForEach(others) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } else if disposition == .new {
                    Section("New catalog") { TextField("Catalog name", text: $name).accessibilityIdentifier("catalog.destinationName") }
                } else {
                    Section { Text("These papers will be removed from your library. The catalog stays visible until the removals finish syncing.") }
                }
                if let issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("catalog.deleteIssue") } }
                if model.catalogBusy {
                    ProgressView(model.catalogDeletionProgress ?? "Saving…").accessibilityIdentifier("catalog.deleting")
                } else {
                    Button(disposition == .deletePapers ? "Delete catalog and papers" : "Move papers and delete catalog", role: .destructive) {
                        if disposition == .deletePapers { confirmDelete = true } else { remove() }
                    }.disabled(!valid || !model.canManageCatalogs).accessibilityIdentifier("catalog.deleteConfirm")
                }
            }.disabled(model.catalogBusy)
                .navigationTitle("Delete catalog").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.catalogBusy) }
                }
                .confirmationDialog("Delete \(catalog.name) and its \(catalogPaperCount(model.catalogCount(catalog.id)))?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete catalog and papers", role: .destructive) { remove() }
                    Button("Cancel", role: .cancel) { }
                }
                .interactiveDismissDisabled(model.catalogBusy)
        }
    }
    private func remove() {
        let scope = model.catalogScope, selection = disposition, target = destination, newName = name
        issue = nil; model.catalogBusy = true
        Task {
            defer { if model.catalogScope == scope { model.catalogBusy = false } }
            do {
                if selection == .deletePapers { try await model.deleteCatalogAndPapers(catalog.id) }
                else { try await model.retireCatalog(catalog.id, movingTo: target, newName: selection == .new ? newName : nil) }
                if model.catalogScope == scope { dismiss() }
            } catch {
                if model.catalogScope == scope { issue = (error as? LibraryCatalogError)?.errorDescription ?? "This catalog is still available. Couldn’t finish the change; try again." }
            }
        }
    }
}
