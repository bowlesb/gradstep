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
    case device, authors, year, venue, tags, source, pages, added, opened, chats, progress

    typealias Column = PaperTableColumn<LibrarySearchSort.Field>
    static let title = Column(id: "title", title: "Title", sortKey: .title, ascendingFirst: true)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: "Device"; case .authors: "Authors"; case .year: "Year"; case .venue: "Venue"; case .tags: "Tags"; case .source: "Source"; case .pages: "Pages"; case .added: "Added"
        case .opened: "Opened"; case .chats: "Chats"; case .progress: "Progress"
        }
    }

    /// What the column chooser says about it.
    var explanation: String {
        switch self {
        case .device: "What is available on this device"
        case .authors: "The paper’s authors"
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
        case .device: 0; case .progress: 1; case .year: 2; case .authors: 3; case .added: 4; case .opened: 5; case .chats: 6; case .tags: 7; case .pages: 8; case .source: 9
        case .venue: 10
        }
    }

    /// At the default text size; grows with Dynamic Type.
    var width: CGFloat {
        switch self {
        case .device: 48; case .authors: 168; case .year: 40; case .venue: 120; case .tags: 150; case .source: 88; case .pages: 44; case .added: 76; case .opened: 76; case .chats: 46
        case .progress: 100
        }
    }

    /// The order its header sets; nil for a column that doesn't sort (Venue).
    var sortField: LibrarySearchSort.Field? {
        switch self {
        case .device: nil; case .authors: .authors; case .year: .year; case .tags: .tags; case .source: .source; case .pages: .pages; case .added: .recent
        case .opened: .opened; case .chats: .chats; case .progress: .progress; case .venue: nil
        }
    }

    var column: Column {
        Column(id: rawValue, title: title, priority: priority, width: width, alignment: alignment,
               sortKey: sortField, ascendingFirst: sortField?.defaultAscending ?? true)
    }

    /// Numbers line up at the trailing edge; Device's glyphs (check, cloud, warning) sit centred under their header, the
    /// header and every glyph sharing one centre (owner, TestFlight 92: "Is the check mark right in the middle of the
    /// column?"); everything else reads from the leading edge.
    var alignment: Alignment {
        switch self {
        case .pages, .chats: .trailing
        case .device: .center
        default: .leading
        }
    }

    /// The columns turned on, in row order. Those that don't fit the width scroll sideways (`TableArrangement`).
    static func columns(_ enabled: Set<Self>) -> [Column] { allCases.filter(enabled.contains).map(\.column) }

    /// What VoiceOver reads for this column of a row.
    func spoken(_ item: LibraryTableItem, now: Date = Date()) -> String? {
        let facts = item.facts
        switch self {
        case .device: return facts.deviceCopy?.label
        case .authors: return facts.authors
        case .year: return facts.year.map(String.init)
        case .venue: return facts.paper?.venue.map { "Published in \($0)" }
        case .tags: return facts.tags.isEmpty ? nil : "Tags: " + facts.tags.joined(separator: ", ")
        case .source: return facts.spokenSource
        case .pages: return facts.pages.map { $0 == 1 ? "1 page" : "\($0) pages" }
        case .added: return facts.added.map { "Added " + LibraryFormat.relativeDayInSentence($0, now: now) }
        case .opened:
            guard facts.paper != nil else { return nil }
            return facts.opened.map { "Opened " + LibraryFormat.relativeDayInSentence($0, now: now) } ?? "Not opened"
        case .chats: return LibraryFormat.chats(facts.chats)
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
/// Get credits, Remove) in its Progress cell, or in its title's second line when Progress isn't shown. Long-press and
/// swipe keep the list's row actions.
struct LibraryPaperTable<Top: View>: View {
    @Bindable var model: ReaderModel
    @ViewBuilder var top: Top
    @Environment(\.wideBar) private var wideBar

    var body: some View {
        let items = model.libraryRows.map { LibraryTableItem(entry: $0, facts: model.libraryFacts(for: $0)) }
        let enabled = model.libraryColumns[LibraryColumnSettings.WidthClass.current]
        // Every chosen column shows (they scroll sideways when they don't fit), so this is whether Progress is shown.
        let progressShown = enabled.contains(.progress)
        PaperTable(rows: items, titleColumn: LibraryTableColumn.title, columns: LibraryTableColumn.columns(enabled),
                   sort: sort, extraSortTitles: [.authors: LibrarySearchSort.Field.authors.label], horizontalScroll: true, rowAlignment: .center,
                   identifier: "library.table",
                   rowIdentifier: { "library.table.\($0.id)" },
                   title: { item in
                       PaperTableTitle(title: item.facts.title, highlighted: isSelected(item.entry),
                                       reservesSpace: true, reservesSubtitleSpace: false, match: model.libraryMatches[item.entry.id],
                                       note: model.libraryRelated[item.entry.id]?.text,
                                       // Without the Progress column an import still shows what it is doing, and its action,
                                       // in its title's second line, so its row is a ready row's height (JUDGMENT_LOG 17).
                                       status: item.isImport && !progressShown ? AnyView(LibraryImportStatusLine(
                                           item: item, act: { perform($0, on: item) }, enabled: model.canChangeImports,
                                           explain: { model.showImportHelp = true })) : nil)
                   },
                   cell: { item, column in
                       LibraryTableCell(item: item, column: LibraryTableColumn(rawValue: column), model: model,
                                        download: item.facts.paper.map { paper in { model.prepareOnDevice(paper) } },
                                        isNew: model.isNew(item.facts.paper),
                                        act: { perform($0, on: item) }, enabled: model.canChangeImports, explain: { model.showImportHelp = true })
                   },
                   cellIsControl: { item, column in
                       (column == LibraryTableColumn.device.rawValue && item.facts.deviceCopy == .cloud)
                           || (column == LibraryTableColumn.progress.rawValue && (item.facts.importAction != nil || item.facts.importProgress != nil))
                           || (column == LibraryTableColumn.tags.rawValue && !item.facts.tags.isEmpty)
                   },
                   spoken: { item, column in LibraryTableColumn(rawValue: column)?.spoken(item) },
                   primaryAction: { action(for: $0) },
                   menu: { LibraryRowActions(model: model, entry: $0.entry, inTable: true) },
                   swipe: { LibrarySwipeActions(model: model, entry: $0.entry) },
                   detail: { _, _ in },
                   top: { top })
        // Turned upright with a paper beside the list: its row centred and tinted, the tint fading (owner, 2026-10-23).
        .revealing(model.revealedRow(in: .library, wide: wideBar))
    }

    private var sort: Binding<PaperTableSort<LibrarySearchSort.Field>> {
        Binding(get: { PaperTableSort(key: model.librarySort.field, ascending: model.librarySort.ascending) },
                set: { model.librarySort = LibrarySearchSort(field: $0.key, ascending: $0.ascending) })
    }

    /// The open paper is highlighted only where it is shown beside the table (iPad Browse).
    private func isSelected(_ entry: LibraryListEntry) -> Bool {
        guard model.browsing, Platform.isLargeScreen, case .paper(let paper) = entry else { return false }
        return model.selectedPaper?.id == paper.id
    }

    private func action(for item: LibraryTableItem) -> PaperTableAction? {
        switch item.entry {
        case .paper(let paper): return PaperTableAction(hint: "Opens the paper") { model.openLibraryResult(paper) }
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
    /// The tag chips' choices (Filter, Filter + related, Search ML papers); nil: chips are labels.
    var model: ReaderModel? = nil
    var download: (() -> Void)? = nil
    var isNew = false
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    var explain: (() -> Void)? = nil
    /// The Device column's glyph box (the cloud's tap target).
    static let deviceGlyphBox: CGFloat = 32

    var body: some View {
        let facts = item.facts
        switch column {
        case .device:
            if let copy = facts.deviceCopy {
                // Every state in the same box, centred in the column (LibraryTableColumn.alignment), so a check and a cloud
                // share the header's centre.
                let symbol = Image(systemName: copy.symbol).font(.subheadline)
                    .foregroundStyle(copy == .reader || copy == .pdf ? Color.accentColor : copy == .unavailable ? .orange : .secondary)
                    .frame(width: LibraryTableCell.deviceGlyphBox, height: LibraryTableCell.deviceGlyphBox)
                if copy == .cloud, let download {
                    Button(action: download) { symbol.contentShape(Rectangle()) }.buttonStyle(.plain)
                        .accessibilityLabel("Download to this device").help("Download to this device")
                } else { symbol.accessibilityLabel(copy.label).help(copy.label) }
            }
        case .authors: Text(facts.authors ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        case .year: PaperTableText(text: facts.year.map(String.init))
        case .venue: Text(facts.paper?.venue ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
        case .tags:
            if let model { LibraryTagChips(model: model, tags: Array(facts.tags.prefix(4))) }
            else { PaperTableChips(tags: Array(facts.tags.prefix(4))) }
        case .source: Text(facts.source ?? "").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            .lineLimit(1).truncationMode(.middle)
        case .pages: PaperTableText(text: facts.pages.map(String.init))
        case .added: PaperTableDate(date: facts.added, placeholder: "—")
        // "—" for a paper never opened on this device; imports have no reading activity.
        case .opened: PaperTableDate(date: facts.opened, placeholder: facts.paper == nil ? nil : "—")
        case .chats: PaperTableText(text: String(facts.chats))
        case .progress: LibraryProgressCell(item: item, isNew: isNew, act: act, enabled: enabled, explain: explain)
        case nil: EmptyView()
        }
    }
}

/// Progress: how far this device has read a paper, or what an import is doing or needs. Compact (an icon and a short
/// status); a stopped import adds its one action as a button (owner feedback 2026-10-07: "it should be a retry button
/// at the very least"). VoiceOver reads the full status through the row; the button is its own element.
struct LibraryProgressCell: View {
    let item: LibraryTableItem
    /// Added recently and not opened on this device: "New" where "—" would be (owner, build 42 asked for the signal;
    /// build 75 found its purple dot beside the checkmark confusing).
    var isNew = false
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    /// "Why does this take a minute?" beside an import's progress.
    var explain: (() -> Void)? = nil

    var body: some View {
        let facts = item.facts
        if let progress = facts.importProgress {
            // An import under way: "Reading 62%", a slim bar, "40 s left" (pipeline progress, 2026-10-07).
            ImportProgressView(progress: progress, style: .compact, explain: explain)
        // Waiting in the queue isn't work yet: no spinner (below, with its time).
        } else if let step = facts.step, step != .queued {
            HStack(alignment: .center, spacing: 6) {
                ImportActivitySpinner()
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.tableTitle).lineLimit(1)
                    if let timing = facts.stepTiming, timing.step == step { StepTimeText(timing: timing) }
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        } else {
            switch facts.status {
            case .active(let text):
                Label { Text(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) } icon: {
                    ImportActivitySpinner()
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
                } else if isNew {
                    PaperTableText(text: "New").accessibilityLabel("New, not opened yet")
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
    var lines = 2
    var body: some View {
        Label { Text(text).lineLimit(lines).fixedSize(horizontal: false, vertical: lines > 1) } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).imageScale(.small)
        }
        .labelStyle(LibraryStatusLabelStyle()).font(.footnote).foregroundStyle(.secondary)
    }
}

/// A stopped import's action: a small bordered capsule ("Retry"), easy to see and to tap.
struct LibraryImportActionButton: View {
    let action: LibraryImportAction
    var enabled = true
    /// `.mini` in a title's second line, where it shares one line's height.
    var size = ControlSize.small
    /// The row's identifier, so tests and VoiceOver can tell rows' buttons apart.
    let sourceID: String
    let perform: () -> Void
    var body: some View {
        Button(action: perform) {
            Text(action.title).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(size)
        .tint(action == .remove ? Color.secondary : Color.accentColor)
        .disabled(!enabled)
        .accessibilityHint(action.hint)
        .accessibilityIdentifier("library.import.\(action.title.lowercased().replacingOccurrences(of: " ", with: "-")).\(sourceID)")
    }
}

/// An import's status in its title's second line when the Progress column isn't shown (`PaperTableTitle.status`): the
/// spinner and one word while it runs ("Adding"), or what stopped it and its action, on that one line, so the row keeps
/// a ready row's height (owner, builds 58–59; JUDGMENT_LOG 17).
struct LibraryImportStatusLine: View {
    let item: LibraryTableItem
    var act: (LibraryImportAction) -> Void = { _ in }
    var enabled = true
    /// "Why does this take a minute?" beside an import's progress.
    var explain: (() -> Void)? = nil
    var body: some View {
        let facts = item.facts
        HStack(alignment: .center, spacing: 8) {
            status(facts)
            Spacer(minLength: 4)
            if let action = facts.importAction {
                LibraryImportActionButton(action: action, enabled: enabled || action == .getCredits, size: .mini, sourceID: item.id) { act(action) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Only the action and the ⓘ take taps; the words let them through to the row under the line.
    @ViewBuilder private func status(_ facts: LibraryRowFacts) -> some View {
        if let progress = facts.importProgress {
            ImportProgressView(progress: progress, style: .line, explain: explain)
        } else {
            words(facts).allowsHitTesting(false)
        }
    }

    @ViewBuilder private func words(_ facts: LibraryRowFacts) -> some View {
        // Waiting in the queue isn't work yet: no spinner (its words below).
        if let step = facts.step, step != .queued {
            HStack(alignment: .center, spacing: 6) { ImportActivitySpinner(); Text(step.tableTitle).lineLimit(1) }
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore).accessibilityLabel(step.tableTitle)
        } else if case .problem(let text) = facts.status {
            // The Progress column's words ("Download failed"), which fit beside the action; VoiceOver reads the sentence.
            LibraryProblemLabel(text: text, lines: 1).accessibilityLabel(item.statusDescription ?? text)
        } else if case .active(let text) = facts.status {
            Label { Text(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))).lineLimit(1) } icon: { ImportActivitySpinner() }
                .labelStyle(LibraryStatusLabelStyle()).font(.footnote).foregroundStyle(.secondary)
        } else if let text = facts.statusText {
            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
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

/// Keep status icons centered beside their text.
struct LibraryStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 6) { configuration.icon.accessibilityHidden(true); configuration.title }
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
            Button("Find similar papers", systemImage: "doc.text.magnifyingglass") { model.findSimilarPapers(paper) }
            RecommendSimilarMenu(model: model, paper: paper)
            PaperShareMenu(paper: paper)
            if model.deviceCopy(for: paper) == .cloud {
                if model.isPreparingOnDevice(paper) {
                    Button("Stop downloading", systemImage: "xmark.circle") { model.cancelDevicePreparation(paper) }
                } else {
                    Button("Download to this device", systemImage: "icloud.and.arrow.down") { model.prepareOnDevice(paper) }
                }
            }
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
                Menu("Move to catalog", systemImage: "folder") {
                    ForEach(model.libraryCatalogs.catalogs) { catalog in
                        Button(catalog.name) {
                            let scope = model.catalogScope
                            Task {
                                do { try await model.movePaper(paper, toCatalog: catalog.id) }
                                catch { if model.catalogScope == scope { model.error = (error as? LibraryCatalogError)?.errorDescription ?? "Couldn’t move this paper. Try again." } }
                            }
                        }.disabled(model.libraryCatalogs.catalogID(for: model.catalogKey(paper)) == catalog.id)
                    }
                }.disabled(!model.canManageCatalogs)
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
            // Source-only arXiv papers stay local; an existing local copy opens in the native PDF viewer (so does a failed
            // web import's PDF saved on this device).
            if item.phase == .sourceOnly || item.phase == .failed, model.localPaperAvailable(for: item) {
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

// MARK: Tags

/// The Library table's tag chips. A tap (a click on iPad and Mac) opens the tag's choices as a menu (owner, TestFlight 92:
/// "It just filters right now but I'd like a few different options"). Each chip is a button for VoiceOver and Full
/// Keyboard Access; the chip of the tag the Library is filtered by is drawn in the accent colour.
struct LibraryTagChips: View {
    @Bindable var model: ReaderModel
    let tags: [String]
    var body: some View {
        PaperTableChipFlow(spacing: 4, lineSpacing: 4, maxLines: 2) {
            ForEach(tags, id: \.self) { tag in
                Menu { LibraryTagActions(model: model, tag: tag) } label: {
                    PaperTableChipLabel(tag: tag, on: tag == model.libraryTagFilter)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("Tag: \(tag)")
                .accessibilityValue(tag == model.libraryTagFilter ? (model.libraryTagIncludesRelated ? "Filtered, with related papers" : "Filtered") : "")
                .accessibilityHint("Filter, Filter + related, or Search ML papers")
                .accessibilityIdentifier("library.tagChip.\(tag)")
                #if targetEnvironment(macCatalyst)
                .help("Filter by “\(tag)”, with related papers, or search ML papers")
                #endif
            }
        }
        .clipped()
    }
}

/// A tag's choices wherever the Library offers them as a menu (a tag chip; the Tags menu has the same, arranged as its
/// own): Filter (the papers with the tag), Filter + related (also untagged papers close to them or using the tag's words;
/// TagRelated) and Search ML papers for the tag's words. The current one is checked; Show all papers clears it.
struct LibraryTagActions: View {
    @Bindable var model: ReaderModel
    let tag: String
    var body: some View {
        let chosen = model.libraryTagFilter == tag
        Section(tag) {
            Button { model.filterLibrary(byTag: tag, related: false) } label: {
                if chosen && !model.libraryTagIncludesRelated { Label("Filter", systemImage: "checkmark") } else { Text("Filter") }
            }
            .accessibilityIdentifier("library.tag.filter")
            Button { model.filterLibrary(byTag: tag, related: true) } label: {
                if chosen && model.libraryTagIncludesRelated { Label("Filter + related", systemImage: "checkmark") } else { Text("Filter + related") }
                Text("Adds related papers that aren’t tagged")
            }
            .accessibilityIdentifier("library.tag.related")
            // The tag's plain words: arXiv has no keyword field, and these are Gradstep's tags (paper-search.ts ANDs the
            // words and favours titles with the whole phrase).
            Button { model.searchPapers(tag) } label: { Label("Search ML papers for “\(tag)”", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("library.tag.search")
        }
        if chosen {
            Button { model.libraryTagFilter = nil } label: { Label("Show all papers", systemImage: "xmark") }
                .accessibilityIdentifier("library.tag.clear")
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

    /// One chip for tags: "Tags ⌄", or the chosen tag ("… + related" with its related papers). Most used first. At the top,
    /// for the chosen tag Include related papers and ML paper search, or ML paper search for one of them (owner, build 75:
    /// "a Search ML papers for tag at the top… either external or internal": the tag rows below are the internal one).
    private func tagMenu(_ summary: LibraryFilterSummary) -> some View {
        let related = model.libraryTagFilter != nil && model.libraryTagIncludesRelated
        return Menu {
            Section {
                if let tag = model.libraryTagFilter {
                    // Filter + related (owner, TestFlight 92), kept when another tag is chosen below.
                    Toggle(isOn: $model.libraryTagIncludesRelated) {
                        Text("Include related papers"); Text("Untagged papers close to these or using the words")
                    }
                    .accessibilityIdentifier("library.tags.related")
                    Button("Search ML papers for “\(tag)”", systemImage: "magnifyingglass") { model.searchPapers(tag) }
                        .accessibilityIdentifier("library.tags.search")
                } else if !summary.tags.isEmpty {
                    Menu {
                        ForEach(summary.tags, id: \.tag) { entry in Button(entry.tag) { model.searchPapers(entry.tag) } }
                    } label: { Label("Search ML papers for a tag", systemImage: "magnifyingglass") }
                        .accessibilityIdentifier("library.tags.search")
                }
            }
            Button { model.libraryTagFilter = nil } label: {
                if model.libraryTagFilter == nil { Label("All tags", systemImage: "checkmark") } else { Text("All tags") }
            }
            Section {
                ForEach(summary.tags, id: \.tag) { entry in
                    Button { model.filterLibrary(byTag: entry.tag, related: related) } label: {
                        if model.libraryTagFilter == entry.tag { Label(entry.tag, systemImage: "checkmark") } else { Text(entry.tag) }
                        Text(entry.count == 1 ? "1 paper" : "\(entry.count) papers")
                    }
                }
            }
        } label: {
            ChipLabel(title: model.libraryTagFilter.map { related ? "\($0) + related" : $0 } ?? "Tags", selected: model.libraryTagFilter != nil,
                      systemImage: "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.libraryTagFilter.map { related ? "Tag: \($0), with related papers" : "Tag: \($0)" } ?? "Tags")
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
    @SheetDismiss private var dismiss
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
