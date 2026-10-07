import SwiftUI
import ScienceReaderCore

extension LocalLibraryCommand {
    var libraryStatus: String {
        if failure == .operationConflict { return "Needs review" }
        switch phase {
        case .held: return "Waiting for the earlier change"
        case .prepared: return "Queued on this device"
        case .submittedUnknown: return "Waiting to confirm"
        case .receiptAwaitingCatchup: return "Updating library…"
        case .needsReview: return "Library changed · review needed"
        case .blocked: return "Waiting to sync"
        case .finished: return "Updated"
        case .cancelled: return "Cancelled"
        }
    }
    var libraryAction: String {
        switch mutation {
        case .beginImport: "Import paper"
        case .setMembership(_, let present, _, _): present ? "Add to library" : "Remove from library"
        case .cancelImport: "Cancel import"
        case .retryImport: "Retry import"
        case .setArchived(_, let archived, _): archived ? "Archive" : "Unarchive"
        case nil:
            switch successor {
            case .cancelImport: "Cancel import"
            case .setMembership(let present, _): present ? "Undo removal" : "Undo addition"
            case .setArchived(let archived): archived ? "Undo unarchive" : "Undo archive"
            case nil: "Library change"
            }
        }
    }
    var libraryUndoTitle: String? {
        guard phase != .needsReview else { return nil }
        if !everSubmitted { return "Discard pending action" }
        switch mutation {
        case .beginImport, .retryImport: return "Cancel import"
        case .setMembership(_, let present, _, _): return present ? "Undo addition" : "Undo removal"
        case .setArchived(_, let archived, _): return archived ? "Undo archive" : "Undo unarchive"
        default: return nil
        }
    }
}

struct LibraryChangesView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.libraryCommands.isEmpty { Text("All library changes are up to date.").foregroundStyle(.secondary) }
                ForEach(model.libraryCommands) { command in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(command.display ?? command.libraryAction).font(.headline)
                        Text("\(command.libraryAction) · \(command.libraryStatus)").font(.caption).foregroundStyle(.secondary)
                        if command.phase == .needsReview {
                            Button("Dismiss") { Task { await model.dismissLibraryChange(command) } }
                                .disabled(!model.canChangeLibrary)
                        } else if let title = command.libraryUndoTitle {
                            Button(title) { Task { await model.cancelLibraryChange(command) } }.disabled(!model.canChangeLibrary)
                        }
                    }.padding(.vertical, 4).accessibilityIdentifier("library.change.\(command.id.wire)")
                }
            }.navigationTitle("Pending changes").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Retry") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing) }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
