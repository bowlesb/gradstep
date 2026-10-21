import SwiftUI
import ScienceReaderCore

extension LocalLibraryCommand {
    var libraryStatus: String {
        if failure == .operationConflict { return "Needs review" }
        if let failure, LibraryCommandCoordinator.temporary(failure), isUnfinished { return "Not sent yet · will retry automatically" }
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
        case .setTags, .setSourceDetails: "Edit paper"
        case nil:
            switch successor {
            case .cancelImport: "Cancel import"
            case .setMembership(let present, _): present ? "Undo removal" : "Undo addition"
            case .setArchived(let archived): archived ? "Undo unarchive" : "Undo archive"
            case .setTags: "Edit tags"
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
                        Text(model.libraryChangeTitle(command)).font(.headline).lineLimit(2)
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
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Try now") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing).macBarButton()
                            .accessibilityIdentifier("library.changes.tryNow")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// Owner, build 73 ("Awful. Unclear product experience"): the Library said "Your change is saved on this device. Refresh to
// try sending it again." the moment any change was queued. A change is now mentioned only once it has waited a while or
// failed a few times, in calm words, and in orange only when the reader has to do something.
extension ReaderModel {
    enum LibrarySyncNotice: Equatable { case waiting(Int), needsAction(String) }

    /// How long a change may wait unmentioned (the coordinator keeps retrying meanwhile).
    static let librarySyncPatience: TimeInterval = 30

    var librarySyncNotice: LibrarySyncNotice? {
        let actionable = libraryCommands.contains { command in
            command.phase == .needsReview || command.failure.map { $0 != .suspended && !LibraryCommandCoordinator.temporary($0) } == true
        }
        if actionable || libraryCommandsHalted { return .needsAction(libraryCommandIssue ?? "A library change needs your review.") }
        let waiting = libraryCommands.filter(\.isUnfinished)
        guard !waiting.isEmpty, libraryCommandsOverdue || waiting.contains(where: { $0.attemptCount >= 3 }) else { return nil }
        return .waiting(waiting.count)
    }

    func noteLibraryCommandAges() {
        let now = Date(), waiting = libraryCommands.filter(\.isUnfinished), ids = Set(waiting.map(\.id))
        libraryCommandSeen = libraryCommandSeen.filter { ids.contains($0.key) }
        for command in waiting where libraryCommandSeen[command.id] == nil { libraryCommandSeen[command.id] = now }
        libraryCommandAgeCheck?.cancel(); libraryCommandAgeCheck = nil
        let remaining = libraryCommandSeen.values.min().map { Self.librarySyncPatience - now.timeIntervalSince($0) }
        let overdue = remaining.map { $0 <= 0 } ?? false
        if libraryCommandsOverdue != overdue { libraryCommandsOverdue = overdue }
        guard let remaining, remaining > 0 else { return }
        libraryCommandAgeCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.noteLibraryCommandAges()
        }
    }

    /// The paper a queued change is about, by its title where the Library knows it (not "arXiv 2412…").
    func libraryChangeTitle(_ command: LocalLibraryCommand) -> String {
        func importTitle(_ id: UUID) -> String? {
            libraryImports.first { $0.id == id }?.metadata?.title ?? papers.first { $0.sourceMembership?.membershipID == id }?.title
        }
        let title: String?
        switch command.mutation {
        case .beginImport(let source, _, _):
            title = libraryImports.first { $0.sourceID == source }?.metadata?.title ?? papers.first { $0.sourceID == source }?.title
                ?? discoveryResults.first { $0.sourceID == source }?.title
        case .setMembership(let id, _, _, _), .setArchived(let id, _, _), .setTags(let id, _, _, _): title = papers.first { $0.id == id }?.title
        case .cancelImport(let id, _), .retryImport(let id, _), .setSourceDetails(let id, _, _, _): title = importTitle(id)
        case nil: title = nil
        }
        return title ?? command.display ?? command.libraryAction
    }
}
