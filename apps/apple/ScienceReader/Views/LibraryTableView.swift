import SwiftUI
import ScienceReaderCore

/// One Library table row: the entry and its facts, computed once per row.
struct LibraryTableItem: Identifiable {
    let entry: LibraryListEntry
    let facts: LibraryRowFacts
    var id: String { entry.id }

    /// "Vaswani et al."; the joined byline when names are unknown (the sample).
    var firstAuthor: String? {
        switch entry {
        case .paper(let paper): LibraryFormat.firstAuthor(for: paper)
        case .pending(let item): LibraryFormat.firstAuthor(item.metadata?.authors ?? [])
        case .queued: nil
        }
    }
    /// An import in progress: the step it is on.
    var step: LibraryImportStep? { if case .pending(let item) = entry { item.step } else { nil } }
    /// The full status, for VoiceOver ("Not enough credits to convert this paper").
    var statusDescription: String? { if case .pending(let item) = entry { item.libraryStatus } else { facts.statusText } }
}

/// The Library's columns. Phone portrait has room for the title, Progress and Year; landscape and iPad add the
/// dates and chats; wide iPads add topics.
enum LibraryTableColumn: String {
    case year, topics, added, opened, chats, progress

    typealias Column = PaperTableColumn<LibrarySearchSort.Field>
    static let title = Column(id: "title", title: "Title", sortKey: .title, ascendingFirst: true)

    /// In row order. Progress is last: it carries an import's status, the column with the most to say.
    static func all(showTopics: Bool) -> [Column] {
        [Column(id: year.rawValue, title: "Year", priority: 1, width: 40, sortKey: .year),
         showTopics ? Column(id: topics.rawValue, title: "Topics", priority: 5, width: 150) : nil,
         Column(id: added.rawValue, title: "Added", priority: 2, width: 76, sortKey: .recent),
         Column(id: opened.rawValue, title: "Opened", priority: 3, width: 76, sortKey: .opened),
         Column(id: chats.rawValue, title: "Chats", priority: 4, width: 46, sortKey: .chats),
         Column(id: progress.rawValue, title: "Progress", priority: 0, width: 100, sortKey: .progress)].compactMap { $0 }
    }

    /// What VoiceOver reads for this column of a row.
    func spoken(_ item: LibraryTableItem, now: Date = Date()) -> String? {
        let facts = item.facts
        switch self {
        case .year: return facts.year.map(String.init)
        case .topics: return facts.topics.isEmpty ? nil : facts.topics.joined(separator: ", ")
        case .added: return facts.added.map { "Added " + LibraryFormat.relativeDayInSentence($0, now: now) }
        case .opened:
            guard facts.paper != nil else { return nil }
            return facts.opened.map { "Opened " + LibraryFormat.relativeDayInSentence($0, now: now) } ?? "Not opened"
        case .chats: return facts.chats > 0 ? LibraryFormat.chats(facts.chats) : nil
        case .progress:
            if let timing = facts.stepTiming {
                return timing.step.spokenStatus(elapsed: ImportStepElapsed(since: timing.since, now: now))
            }
            switch facts.status {
            case .active, .problem: return item.statusDescription
            case .info where facts.paper == nil: return item.statusDescription
            default:
                guard facts.paper != nil else { return nil }
                return facts.progress.map { "\(LibraryFormat.percent($0)) percent read" } ?? "Not started"
            }
        }
    }
}

/// The Table layout of the Library: `PaperTable` over the library's rows. Tapping a paper opens it as in the list;
/// tapping an import that needs credits opens the store; long-press and swipe keep the list's row actions.
struct LibraryPaperTable<Top: View>: View {
    @Bindable var model: ReaderModel
    @ViewBuilder var top: Top

    var body: some View {
        let items = model.libraryRows.map { LibraryTableItem(entry: $0, facts: model.libraryFacts(for: $0)) }
        PaperTable(rows: items, titleColumn: LibraryTableColumn.title, columns: LibraryTableColumn.all(showTopics: model.showTopics),
                   sort: sort, extraSortTitles: [.authors: LibrarySearchSort.Field.authors.label], identifier: "library.table",
                   rowIdentifier: { "library.table.\($0.id)" },
                   title: { item in
                       PaperTableTitle(title: item.facts.title, subtitle: item.firstAuthor, highlighted: isSelected(item.entry))
                   },
                   cell: { item, column in LibraryTableCell(item: item, column: LibraryTableColumn(rawValue: column)) },
                   spoken: { item, column in LibraryTableColumn(rawValue: column)?.spoken(item) },
                   primaryAction: { action(for: $0) },
                   menu: { LibraryRowActions(model: model, entry: $0.entry, inTable: true) },
                   swipe: { LibrarySwipeActions(model: model, entry: $0.entry) },
                   detail: { _ in EmptyView() },
                   top: { top })
    }

    private var sort: Binding<PaperTableSort<LibrarySearchSort.Field>> {
        Binding(get: { PaperTableSort(key: model.librarySort.field, ascending: model.librarySort.ascending) },
                set: { model.librarySort = LibrarySearchSort(field: $0.key, ascending: $0.ascending) })
    }

    /// The open paper is highlighted only where it is shown beside the table (iPad Browse).
    private func isSelected(_ entry: LibraryListEntry) -> Bool {
        guard model.wideMode == .browse, UIDevice.current.userInterfaceIdiom == .pad, case .paper(let paper) = entry else { return false }
        return model.selectedPaper?.id == paper.id
    }

    private func action(for item: LibraryTableItem) -> PaperTableAction? {
        switch item.entry {
        case .paper(let paper): return PaperTableAction(hint: "Opens the paper") { model.select(paper) }
        case .pending where item.facts.needsCredits: return PaperTableAction(hint: "Opens Get credits") { model.showStore = true }
        default: return nil
        }
    }
}

/// One cell of the Library table.
struct LibraryTableCell: View {
    let item: LibraryTableItem
    let column: LibraryTableColumn?

    var body: some View {
        let facts = item.facts
        switch column {
        case .year: PaperTableText(text: facts.year.map(String.init))
        case .topics:
            Text(facts.topics.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        case .added: PaperTableText(text: facts.added.map { LibraryFormat.relativeDay($0) })
        // "—" for a paper never opened on this device; imports have no reading activity.
        case .opened: PaperTableText(text: facts.opened.map { LibraryFormat.relativeDay($0) } ?? (facts.paper == nil ? nil : "—"))
        // No chats is the usual case: left blank, so the counts stand out.
        case .chats: PaperTableText(text: facts.chats > 0 ? String(facts.chats) : nil)
        case .progress: LibraryProgressCell(item: item)
        case nil: EmptyView()
        }
    }
}

/// Progress: how far this device has read a paper, or what an import is doing or needs. Compact (an icon and a short
/// word that never breaks mid-word); VoiceOver reads the full status through the row.
struct LibraryProgressCell: View {
    let item: LibraryTableItem

    var body: some View {
        let facts = item.facts
        switch facts.status {
        case .active(let text):
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(item.step?.tableTitle ?? text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) } icon: {
                    // Centred on the text rather than sitting on its baseline.
                    ProgressView().controlSize(.mini).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                .labelStyle(LibraryStatusLabelStyle())
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let timing = facts.stepTiming { StepTimeText(timing: timing) }
            }
        case .problem(let text):
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(text).lineLimit(2) } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).imageScale(.small)
                }
                .labelStyle(LibraryStatusLabelStyle()).font(.footnote).foregroundStyle(.secondary)
                // The row's tap opens the store; this says so.
                if facts.needsCredits {
                    Text("Get credits").font(.footnote.weight(.semibold)).foregroundStyle(.tint).lineLimit(1)
                }
            }
        case .info(let text) where facts.paper == nil:
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let timing = facts.stepTiming { StepTimeText(timing: timing) }
            }
        default:
            // A paper ready to read (or simply not downloaded yet, which the list doesn't flag either).
            if let progress = facts.progress {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LibraryProgressBar(value: progress).frame(width: 28).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text("\(LibraryFormat.percent(progress))%").font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            } else {
                PaperTableText(text: facts.paper == nil ? nil : "—")
            }
        }
    }
}

/// How long an import has been on its step ("1 min", then "Taking longer than usual"), changing once a minute
/// without animation.
private struct StepTimeText: View {
    let timing: ImportStepTiming
    var body: some View {
        TimelineView(.periodic(from: timing.since, by: 60)) { context in
            if let label = ImportStepElapsed(since: timing.since, now: context.date).label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Icon and text on the first baseline, tightly spaced.
struct LibraryStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) { configuration.icon.accessibilityHidden(true); configuration.title }
    }
}

/// A small reading-progress bar.
struct LibraryProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor).frame(width: max(value > 0 ? 3 : 0, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4).accessibilityHidden(true)
    }
}

/// The long-press actions of a Library row, shared by the list, detailed rows and the table.
struct LibraryRowActions: View {
    @Bindable var model: ReaderModel
    let entry: LibraryListEntry
    var inTable = false
    var body: some View {
        switch entry {
        case .paper(let paper):
            if !paper.isSample {
                let archived = model.isArchived(paper)
                Button(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
                    Task { await model.setArchived(paper, archived: !archived) }
                }.disabled(!model.canChangeLibrary)
                Button("Remove from library", systemImage: "minus.circle", role: .destructive) { Task { await model.removePaper(paper) } }
                    .disabled(!model.canChangeLibrary)
            }
        case .pending(let item):
            if item.phase == .failed && item.retryable {
                Button("Retry import", systemImage: "arrow.clockwise") { Task { await model.changeImport(item, retry: true) } }
                    .disabled(!model.canChangeLibrary)
            }
            if inTable, item.phase == .failed, item.errorCode == .insufficientCredits {
                Button("Get credits", systemImage: "creditcard") { model.showStore = true }
            }
            if inTable, item.phase != .resolving, item.phase != .acquiring, let url = URL(string: item.sourceURL) {
                Link(destination: url) { Label("View source", systemImage: "safari") }
            }
            Button("Cancel import", systemImage: "xmark.circle", role: .destructive) { Task { await model.changeImport(item, retry: false) } }
                .disabled(!model.canChangeLibrary)
        case .queued(let command):
            Button("Cancel import", systemImage: "xmark.circle", role: .destructive) { Task { await model.cancelLibraryChange(command) } }
                .disabled(!model.canChangeLibrary)
        }
    }
}

/// Swipe actions of a Library row (owner feedback 2026-10-06: remove and archive by swiping, as in Mail; cancel and
/// retry an import the same way). The same actions as the long-press menu; shared by every layout.
struct LibrarySwipeActions: View {
    @Bindable var model: ReaderModel
    let entry: LibraryListEntry
    var body: some View {
        switch entry {
        case .paper(let paper):
            if !paper.isSample {
                Button(role: .destructive) { Task { await model.removePaper(paper) } } label: { Label("Remove", systemImage: "trash") }
                    .tint(.red).disabled(!model.canChangeLibrary)
                let archived = model.isArchived(paper)
                Button { Task { await model.setArchived(paper, archived: !archived) } } label: {
                    Label(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox")
                }.tint(.indigo).disabled(!model.canChangeLibrary)
            }
        case .pending(let item):
            Button(role: .destructive) { Task { await model.changeImport(item, retry: false) } } label: {
                Label("Cancel import", systemImage: "xmark.circle")
            }.tint(.red).disabled(!model.canChangeLibrary)
            if item.phase == .failed && item.retryable {
                Button { Task { await model.changeImport(item, retry: true) } } label: {
                    Label("Retry import", systemImage: "arrow.clockwise")
                }.tint(.accentColor).disabled(!model.canChangeLibrary)
            }
        case .queued:
            EmptyView()
        }
    }
}

/// "Detailed rows": title, then authors · year · topics, then this device's activity; unknown facts are left out
/// rather than printed blank. Also what the Table layout shows at accessibility text sizes.
struct DetailedPaperRow: View {
    let facts: LibraryRowFacts
    var selected = false
    var offlineStatus: PaperOfflineStatus = .none
    var showTopics = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(facts.title).font(.headline).foregroundStyle(selected ? Color.accentColor : .primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
                Spacer(minLength: 8)
                if offlineStatus == .available { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Available offline") }
                else if offlineStatus == .unavailable { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("Downloaded copy unavailable") }
            }
            let summary = facts.summaryLine(showTopics: showTopics)
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            }
            let activity = facts.activityLine()
            if !activity.isEmpty {
                Text(activity).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

/// An import in detailed rows: the same facts plus its status and actions, as in the list.
struct DetailedImportRow: View {
    let item: LibraryImportRecord
    let facts: LibraryRowFacts
    var showTopics = true
    var getCredits: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(facts.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 2)
            let summary = facts.summaryLine(showTopics: showTopics)
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            }
            HStack(spacing: 6) {
                if item.isActive { ProgressView().controlSize(.small).accessibilityHidden(true) }
                ImportStatusText(item: item, since: facts.stepTiming?.since, short: true).font(.caption).foregroundStyle(.secondary)
                if item.phase == .failed, item.errorCode == .insufficientCredits, let getCredits {
                    Button("Get credits", action: getCredits).font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("import.getCredits")
                }
                if !item.isActive, let url = URL(string: item.sourceURL) {
                    Spacer(minLength: 8)
                    Link("View source", destination: url).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
