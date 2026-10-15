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
    /// An import in progress (or being retried): the step it is on.
    var step: LibraryImportStep? { facts.step }
    /// The full status, for VoiceOver ("Couldn’t download this paper").
    var statusDescription: String? {
        if let step { return step.title }
        if case .pending(let item) = entry { return item.libraryStatus }
        return facts.statusText
    }
    /// An import or an Add waiting to sync (not a paper yet).
    var isImport: Bool { if case .paper = entry { false } else { true } }
}

/// The Library's columns beside Title (owner request 2026-10-07: "columns that can be turned on or off"). Cases are
/// in row order; Progress is last: it carries an import's status and its Retry, the cell with the most to say.
enum LibraryTableColumn: String, CaseIterable, Identifiable, Sendable {
    case year, venue, tags, source, pages, added, opened, chats, progress

    typealias Column = PaperTableColumn<LibrarySearchSort.Field>
    static let title = Column(id: "title", title: "Title", sortKey: .title, ascendingFirst: true)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .year: "Year"; case .venue: "Venue"; case .tags: "Tags"; case .source: "Source"; case .pages: "Pages"; case .added: "Added"
        case .opened: "Opened"; case .chats: "Chats"; case .progress: "Progress"
        }
    }

    /// What the column chooser says about it.
    var explanation: String {
        switch self {
        case .year: "Year published"
        case .venue: "Where it was published (NeurIPS, a journal)"
        case .tags: "Topics, as chips"
        case .source: "arXiv identifier or website"
        case .pages: "Length of the paper"
        case .added: "When it joined your library"
        case .opened: "Last opened on this device"
        case .chats: "Saved chats about it"
        case .progress: "How far you’ve read; import status and Retry"
        }
    }

    /// 0 is kept longest when the width runs out: progress (and import status), then year, the dates, chats; tags,
    /// pages and source go first.
    var priority: Int {
        switch self {
        case .progress: 0; case .year: 1; case .added: 2; case .opened: 3; case .chats: 4; case .tags: 5; case .pages: 6; case .source: 7
        case .venue: 8
        }
    }

    /// At the default text size; grows with Dynamic Type.
    var width: CGFloat {
        switch self {
        case .year: 40; case .venue: 120; case .tags: 150; case .source: 88; case .pages: 44; case .added: 76; case .opened: 76; case .chats: 46
        case .progress: 100
        }
    }

    /// The order its header sets; nil for a column that doesn't sort (Venue).
    var sortField: LibrarySearchSort.Field? {
        switch self {
        case .year: .year; case .tags: .tags; case .source: .source; case .pages: .pages; case .added: .recent
        case .opened: .opened; case .chats: .chats; case .progress: .progress; case .venue: nil
        }
    }

    var column: Column {
        Column(id: rawValue, title: title, priority: priority, width: width,
               alignment: self == .pages || self == .chats ? .trailing : .leading,
               sortKey: sortField, ascendingFirst: sortField?.defaultAscending ?? true)
    }

    /// The columns turned on, in row order. Those that don't fit the width scroll sideways (`TableArrangement`).
    static func columns(_ enabled: Set<Self>) -> [Column] { allCases.filter(enabled.contains).map(\.column) }

    /// What VoiceOver reads for this column of a row.
    func spoken(_ item: LibraryTableItem, now: Date = Date()) -> String? {
        let facts = item.facts
        switch self {
        case .year: return facts.year.map(String.init)
        case .venue: return facts.paper?.venue.map { "Published in \($0)" }
        case .tags: return facts.tags.isEmpty ? nil : "Tags: " + facts.tags.joined(separator: ", ")
        case .source: return facts.spokenSource
        case .pages: return facts.pages.map { $0 == 1 ? "1 page" : "\($0) pages" }
        case .added: return facts.added.map { "Added " + LibraryFormat.relativeDayInSentence($0, now: now) }
        case .opened:
            guard facts.paper != nil else { return nil }
            return facts.opened.map { "Opened " + LibraryFormat.relativeDayInSentence($0, now: now) } ?? "Not opened"
        case .chats: return facts.chats > 0 ? LibraryFormat.chats(facts.chats) : nil
        case .progress:
            if let progress = facts.importProgress { return progress.presentation(at: now).accessibilityLabel }
            if let timing = facts.stepTiming, timing.step == facts.step {
                return timing.step.spokenStatus(elapsed: ImportStepElapsed(since: timing.since, now: now))
            }
            if let step = facts.step { return step.title }
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

extension LibraryColumnSettings.WidthClass {
    /// iPhone keeps its own columns; iPad and Mac share theirs (the table's width still decides what fits).
    @MainActor static var current: Self { Platform.isLargeScreen ? .regular : .compact }
}

/// The Library as a table: `PaperTable` over the library's rows, with the reader's columns. Tapping a paper opens it
/// as in the list; tapping an import that needs credits opens the store; a stopped import shows its action (Retry,
/// Get credits, Remove) in its Progress cell, or under its title when Progress isn't shown. Long-press and swipe keep
/// the list's row actions.
struct LibraryPaperTable<Top: View>: View {
    @Bindable var model: ReaderModel
    @ViewBuilder var top: Top

    var body: some View {
        let items = model.libraryRows.map { LibraryTableItem(entry: $0, facts: model.libraryFacts(for: $0)) }
        let enabled = model.libraryColumns[LibraryColumnSettings.WidthClass.current]
        PaperTable(rows: items, titleColumn: LibraryTableColumn.title, columns: LibraryTableColumn.columns(enabled),
                   sort: sort, extraSortTitles: [.authors: LibrarySearchSort.Field.authors.label], horizontalScroll: true,
                   identifier: "library.table",
                   rowIdentifier: { "library.table.\($0.id)" },
                   title: { item in
                       PaperTableTitle(title: item.facts.title, subtitle: item.firstAuthor, highlighted: isSelected(item.entry), deviceCopy: item.facts.deviceCopy)
                   },
                   cell: { item, column in
                       LibraryTableCell(item: item, column: LibraryTableColumn(rawValue: column), highlightedTag: model.libraryTagFilter,
                                        act: { perform($0, on: item) }, enabled: model.canChangeImports, explain: { model.showImportHelp = true })
                   },
                   cellIsControl: { item, column in column == LibraryTableColumn.progress.rawValue && (item.facts.importAction != nil || item.facts.importProgress != nil) },
                   spoken: { item, column in LibraryTableColumn(rawValue: column)?.spoken(item) },
                   primaryAction: { action(for: $0) },
                   menu: { LibraryRowActions(model: model, entry: $0.entry, inTable: true) },
                   swipe: { LibrarySwipeActions(model: model, entry: $0.entry) },
                   detail: { item, shown in
                       // Without the Progress column an import still shows what it is doing, and its action.
                       if item.isImport, !shown.contains(LibraryTableColumn.progress.rawValue) {
                           LibraryImportStatusLine(item: item, act: { perform($0, on: item) }, enabled: model.canChangeImports, explain: { model.showImportHelp = true })
                       }
                   },
                   top: { top })
    }

    private var sort: Binding<PaperTableSort<LibrarySearchSort.Field>> {
        Binding(get: { PaperTableSort(key: model.librarySort.field, ascending: model.librarySort.ascending) },
                set: { model.librarySort = LibrarySearchSort(field: $0.key, ascending: $0.ascending) })
    }

    /// The open paper is highlighted only where it is shown beside the table (iPad Browse).
    private func isSelected(_ entry: LibraryListEntry) -> Bool {
        guard model.wideMode == .browse, Platform.isLargeScreen, case .paper(let paper) = entry else { return false }
        return model.selectedPaper?.id == paper.id
    }

    private func action(for item: LibraryTableItem) -> PaperTableAction? {
        switch item.entry {
        case .paper(let paper): return PaperTableAction(hint: "Opens the paper") { model.select(paper) }
        case .pending where item.facts.needsCredits: return PaperTableAction(hint: "Opens Get credits") { model.showStore = true }
        default: return nil
        }
    }

    private func perform(_ action: LibraryImportAction, on item: LibraryTableItem) {
        guard case .pending(let record) = item.entry else { return }
        LibraryImportAction.perform(action, on: record, model: model)
    }
}

extension LibraryImportAction {
    /// Retry and Remove go through the library's change queue (Retry shows the import running again at once).
    @MainActor static func perform(_ action: Self, on item: LibraryImportRecord, model: ReaderModel) {
        switch action {
        case .retry: Task { await model.changeImport(item, retry: true) }
        case .remove: Task { await model.changeImport(item, retry: false) }
        case .getCredits: model.showStore = true
        case .uploadPDF: model.uploads.pickRequest = .init(target: .importID(item.id, revision: item.intentRevision), title: item.metadata?.title)
        case .downloadOnDevice: model.downloadOnDevice(item)
        case .openLocalPDF: model.openLocalPaper(item)
        }
    }

    var hint: String {
        switch self {
        case .retry: "Tries the download again"
        case .getCredits: "Opens Get credits"
        case .remove: "Removes this import from your library"
        case .uploadPDF: "Chooses the paper’s PDF from Files"
        case .downloadOnDevice: "Downloads the PDF over this device’s connection and saves it only here"
        case .openLocalPDF: "Opens the encrypted PDF saved on this device"
        }
    }
}

/// One cell of the Library table.
struct LibraryTableCell: View {
    let item: LibraryTableItem
    let column: LibraryTableColumn?
    var highlightedTag: String? = nil
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    var explain: (() -> Void)? = nil

    var body: some View {
        let facts = item.facts
        switch column {
        case .year: PaperTableText(text: facts.year.map(String.init))
        case .venue: Text(facts.paper?.venue ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
        case .tags: PaperTableChips(tags: Array(facts.tags.prefix(4)), highlighted: highlightedTag)
        case .source: Text(facts.source ?? "").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            .lineLimit(1).truncationMode(.middle)
        case .pages: PaperTableText(text: facts.pages.map(String.init))
        case .added: PaperTableText(text: facts.added.map { LibraryFormat.relativeDay($0) })
        // "—" for a paper never opened on this device; imports have no reading activity.
        case .opened: PaperTableText(text: facts.opened.map { LibraryFormat.relativeDay($0) } ?? (facts.paper == nil ? nil : "—"))
        // No chats is the usual case: left blank, so the counts stand out.
        case .chats: PaperTableText(text: facts.chats > 0 ? String(facts.chats) : nil)
        case .progress: LibraryProgressCell(item: item, act: act, enabled: enabled, explain: explain)
        case nil: EmptyView()
        }
    }
}

/// Progress: how far this device has read a paper, or what an import is doing or needs. Compact (an icon and a short
/// status); a stopped import adds its one action as a button (owner feedback 2026-10-07: "it should be a retry button
/// at the very least"). VoiceOver reads the full status through the row; the button is its own element.
struct LibraryProgressCell: View {
    let item: LibraryTableItem
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    /// "Why does this take a minute?" beside an import's progress.
    var explain: (() -> Void)? = nil

    var body: some View {
        let facts = item.facts
        if let progress = facts.importProgress {
            // An import under way: "Reading 62%", a slim bar, "40 s left" (pipeline progress, 2026-10-07).
            ImportProgressView(progress: progress, style: .compact, explain: explain)
                // Its first line sits on the row's first baseline, like the other cells.
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 13 }
        // Waiting in the queue isn't work yet: no spinner (below, with its time).
        } else if let step = facts.step, step != .queued {
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(step.tableTitle) } icon: {
                    // Centred on the text rather than sitting on its baseline.
                    ProgressView().controlSize(.mini).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                .labelStyle(LibraryStatusLabelStyle())
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let timing = facts.stepTiming, timing.step == step { StepTimeText(timing: timing) }
            }
        } else {
            switch facts.status {
            case .active(let text):
                Label { Text(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) } icon: {
                    ProgressView().controlSize(.mini).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                .labelStyle(LibraryStatusLabelStyle()).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            case .problem(let text):
                VStack(alignment: .leading, spacing: 6) {
                    LibraryProblemLabel(text: text).accessibilityHidden(facts.importAction != nil)
                    if let action = facts.importAction {
                        LibraryImportActionButton(action: action, enabled: enabled || action == .getCredits, sourceID: item.id) { act(action) }
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
}

/// "⚠︎ Download failed": an orange symbol and the status in plain words, never broken mid-word.
struct LibraryProblemLabel: View {
    let text: String
    var body: some View {
        Label { Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).imageScale(.small)
        }
        .labelStyle(LibraryStatusLabelStyle()).font(.footnote).foregroundStyle(.secondary)
    }
}

/// A stopped import's action: a small bordered capsule ("Retry"), easy to see and to tap.
struct LibraryImportActionButton: View {
    let action: LibraryImportAction
    var enabled = true
    /// The row's identifier, so tests and VoiceOver can tell rows' buttons apart.
    let sourceID: String
    let perform: () -> Void
    var body: some View {
        Button(action: perform) {
            Text(action.title).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        .tint(action == .remove ? Color.secondary : Color.accentColor)
        .disabled(!enabled)
        .accessibilityHint(action.hint)
        .accessibilityIdentifier("library.import.\(action.title.lowercased().replacingOccurrences(of: " ", with: "-")).\(sourceID)")
    }
}

/// An import's status under its title when the Progress column isn't shown: what it is doing, or what failed and its
/// action, on one line.
struct LibraryImportStatusLine: View {
    let item: LibraryTableItem
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    var explain: (() -> Void)? = nil
    var body: some View {
        let facts = item.facts
        if let progress = facts.importProgress {
            ImportProgressView(progress: progress, style: .row, explain: explain).font(.footnote).foregroundStyle(.secondary)
        } else {
            line(facts)
        }
    }

    private func line(_ facts: LibraryRowFacts) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let step = facts.step, step != .queued {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text(step.label(short: false)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else if case .problem = facts.status {
                LibraryProblemLabel(text: item.statusDescription ?? facts.statusText ?? "")
            } else if let text = facts.statusText {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let action = facts.importAction {
                LibraryImportActionButton(action: action, enabled: enabled || action == .getCredits, sourceID: item.id) { act(action) }
            }
        }
        .accessibilityElement(children: .contain)
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

/// The long-press actions of a Library row, shared by the list and the table. A stopped import offers Retry (when
/// the server can run it again) and Remove; one still running offers Cancel.
struct LibraryRowActions: View {
    @Bindable var model: ReaderModel
    let entry: LibraryListEntry
    var inTable = false
    var body: some View {
        switch entry {
        case .paper(let paper):
            PodcastListenMenuRow(model: model, paper: paper)
            if let item = model.sourceImport(for: paper) {
                if model.localPaperAvailable(for: item) {
                    Button("Open PDF", systemImage: "doc.text.magnifyingglass") { model.openLocalPaper(item) }
                } else {
                    Button("Download PDF on this device", systemImage: "arrow.down.circle") { model.downloadOnDevice(item) }
                        .disabled(!model.hasLocalPaperStore)
                }
            }
            if !paper.isSample {
                Button("Edit tags", systemImage: "tag") { model.editTags(for: paper) }
                    .disabled(!model.canChangeLibrary)
                let archived = model.isArchived(paper)
                Button(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
                    Task { await model.setArchived(paper, archived: !archived) }
                }.disabled(!model.canChangeLibrary)
                Button("Remove from library", systemImage: "minus.circle", role: .destructive) { Task { await model.removePaper(paper) } }
                    .disabled(!model.canChangeLibrary)
            }
        case .pending(let item):
            let stopped = item.phase == .failed || item.phase == .membershipConflict
            if item.phase == .failed && item.retryable && !model.isRetrying(item) {
                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.changeImport(item, retry: true) } }
                    .disabled(!model.canChangeImports)
            }
            if item.phase == .failed, item.errorCode == .insufficientCredits {
                Button("Get credits", systemImage: "creditcard") { model.showStore = true }
            }
            // Source-only arXiv papers stay local; an existing local copy opens in the native PDF viewer.
            if item.phase == .sourceOnly, model.localPaperAvailable(for: item) {
                Button("Open PDF", systemImage: "doc.text.magnifyingglass") { model.openLocalPaper(item) }
            } else if item.canDownloadOnDevice {
                // A web paper (or a reader's own upload) can take the PDF from this device.
                Button("Download on this device", systemImage: "arrow.down.circle") { model.downloadOnDevice(item) }
                    .disabled(item.phase == .sourceOnly ? !model.hasLocalPaperStore : !model.uploads.isActive)
            }
            if (item.phase == .failed || item.phase == .sourceOnly), item.canTakeUpload {
                Button("Add PDF on this device…", systemImage: "doc.badge.plus") {
                    model.uploads.pickRequest = .init(target: .importID(item.id, revision: item.intentRevision), title: item.metadata?.title)
                }.disabled(!model.uploads.isActive)
            }
            if inTable, item.phase != .resolving, item.phase != .acquiring, let url = item.sourceURL.flatMap({ URL(string: $0) }) {
                Link(destination: url) { Label(item.sourceLinkTitle, systemImage: "safari") }
            }
            Button(stopped ? "Remove" : "Cancel import", systemImage: stopped ? "minus.circle" : "xmark.circle", role: .destructive) {
                Task { await model.changeImport(item, retry: false) }
            }
            .disabled(!model.canChangeImports)
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
            let stopped = item.phase == .failed || item.phase == .membershipConflict
            Button(role: .destructive) { Task { await model.changeImport(item, retry: false) } } label: {
                Label(stopped ? "Remove" : "Cancel import", systemImage: stopped ? "trash" : "xmark.circle")
            }.tint(.red).disabled(!model.canChangeImports)
            if item.phase == .failed && item.retryable && !model.isRetrying(item) {
                Button { Task { await model.changeImport(item, retry: true) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }.tint(.accentColor).disabled(!model.canChangeImports)
            }
        case .queued:
            EmptyView()
        }
    }
}

// MARK: Filters

/// The Library's quick filters, above the table (and the List): the Tags menu, All, then the filters that would show
/// something different (Unread, Reading, Failed with its count, Archived). It scrolls away with the rows, so
/// browsing keeps the open space; it is hidden while there is nothing to narrow down.
struct LibraryFilterBar: View {
    @Bindable var model: ReaderModel

    var body: some View {
        let summary = model.libraryFilterSummary()
        let chips = summary.chips(selected: model.libraryFilter, tagSelected: model.libraryTagFilter != nil)
        if !chips.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Tags first: it combines with the others, and on a phone the row runs past the edge.
                        if summary.showsTags(tagSelected: model.libraryTagFilter != nil) { tagMenu(summary) }
                        ForEach(chips, id: \.self) { filter in
                            ChipButton(title: filter.title, selected: model.libraryFilter == filter,
                                       count: filter == .failed ? summary.count(.failed) : nil, countIsProblem: true) {
                                model.libraryFilter = filter
                            }
                            .accessibilityIdentifier("library.filter.\(filter.rawValue)")
                            .accessibilityValue(filter == .all ? "" : "\(summary.count(filter))")
                        }
                    }
                }
                .contentMargins(.horizontal, DesignMetrics.margin, for: .scrollContent)
                // The chosen filter stays in view (one chosen elsewhere, or past the edge on a phone).
                .onAppear { if model.libraryFilter != .all { proxy.scrollTo(model.libraryFilter, anchor: .center) } }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filters")
            .accessibilityIdentifier("library.filters")
        }
    }

    /// One chip for tags: "Tags ⌄", or the chosen tag. Most used first.
    private func tagMenu(_ summary: LibraryFilterSummary) -> some View {
        Menu {
            Button { model.libraryTagFilter = nil } label: {
                if model.libraryTagFilter == nil { Label("All tags", systemImage: "checkmark") } else { Text("All tags") }
            }
            Section {
                ForEach(summary.tags, id: \.tag) { entry in
                    Button { model.libraryTagFilter = entry.tag } label: {
                        if model.libraryTagFilter == entry.tag { Label(entry.tag, systemImage: "checkmark") } else { Text(entry.tag) }
                        Text(entry.count == 1 ? "1 paper" : "\(entry.count) papers")
                    }
                }
            }
        } label: {
            ChipLabel(title: model.libraryTagFilter ?? "Tags", selected: model.libraryTagFilter != nil, systemImage: "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.libraryTagFilter.map { "Tag: \($0)" } ?? "Tags")
        .accessibilityIdentifier("library.filter.tags")
    }
}

// MARK: Columns

/// Library options › Columns: a toggle per column (Title always shows), for this kind of device. Changes apply at
/// once, so the table behind the half-height sheet shows them; columns turned on that don't fit say they scroll.
struct LibraryColumnsSheet: View {
    @Bindable var model: ReaderModel
    /// The table's row width (inside the margins), to say which chosen columns need more room.
    let tableWidth: CGFloat
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    private let widthClass = LibraryColumnSettings.WidthClass.current

    var body: some View {
        let enabled = model.libraryColumns[widthClass]
        let fitting = Set(PaperTableLayout.visibleColumns(LibraryTableColumn.columns(enabled), width: tableWidth, scale: scale).map(\.id))
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Title")
                            Text("With the first author").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Always shown").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    ForEach(LibraryTableColumn.allCases) { column in
                        Toggle(isOn: binding(column)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(column.title)
                                Text(enabled.contains(column) && !fitting.contains(column.id) ? TableColumnWording.scrolls : column.explanation)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("library.columns.\(column.rawValue)")
                    }
                } footer: {
                    Text(TableColumnWording.footer(widthClass))
                }
                Section {
                    Button("Restore defaults") { model.libraryColumns[widthClass] = LibraryColumnSettings.defaultColumns(widthClass) }
                        .disabled(enabled == LibraryColumnSettings.defaultColumns(widthClass))
                        .accessibilityIdentifier("library.columns.restore")
                }
            }
            .navigationTitle("Columns").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("library.columns.done") }
            }
        }
        .presentationDetents([.medium, .large])
        .macSheetKeys()
    }

    private func binding(_ column: LibraryTableColumn) -> Binding<Bool> {
        Binding(get: { model.libraryColumns[widthClass].contains(column) },
                set: { on in
                    var columns = model.libraryColumns[widthClass]
                    if on { columns.insert(column) } else { columns.remove(column) }
                    model.libraryColumns[widthClass] = columns
                })
    }
}
