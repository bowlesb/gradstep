import SwiftUI
import ScienceReaderCore

/// One table row: the library entry and the metadata snapshot its current order was computed from.
struct LibraryTableRow: Identifiable {
    let entry: LibraryListEntry
    let candidate: LibrarySearchCandidate
    var id: String { entry.id }
}

/// Header sorting for the table. It never sorts by itself: the model's search engine orders the
/// rows, and this comparator delegates to that same ordering so the two cannot disagree.
struct LibraryTableComparator: SortComparator, Hashable {
    let field: LibrarySearchSort.Field
    var order: SortOrder

    init(field: LibrarySearchSort.Field, order: SortOrder? = nil) {
        self.field = field
        self.order = order ?? (field.defaultAscending ? .forward : .reverse)
    }
    init(_ sort: LibrarySearchSort) { self.init(field: sort.field, order: sort.ascending ? .forward : .reverse) }
    var sort: LibrarySearchSort { LibrarySearchSort(field: field, ascending: order == .forward) }

    func compare(_ lhs: LibraryTableRow, _ rhs: LibraryTableRow) -> ComparisonResult {
        if LibrarySearchEngine.ordered(lhs.candidate, before: rhs.candidate, by: sort) { return .orderedAscending }
        if LibrarySearchEngine.ordered(rhs.candidate, before: lhs.candidate, by: sort) { return .orderedDescending }
        return .orderedSame
    }
}

/// Column visibility and order, kept across launches.
enum LibraryTableSettings {
    private static let key = "library.tableColumns"
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
    static func load() -> TableColumnCustomization<LibraryTableRow> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(TableColumnCustomization<LibraryTableRow>.self, from: data) else { return .init() }
        return value
    }
    static func save(_ value: TableColumnCustomization<LibraryTableRow>) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// The wide Library layout: a native table with sortable, customizable columns. Tapping a row
/// opens the paper exactly like the list; long-press keeps the list's row actions.
struct LibraryTable: View {
    @Bindable var model: ReaderModel
    @State private var columns = LibraryTableSettings.load()
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = model.libraryRows.map { LibraryTableRow(entry: $0, candidate: model.librarySearchCandidate(for: $0)) }
        let anyStatus = model.libraryRows.contains { model.libraryStatus(for: $0) != .none }
        let getCredits = { model.showStore = true }
        Table(rows, selection: $selection, sortOrder: sortOrder, columnCustomization: $columns) {
            TableColumn("Title", sortUsing: LibraryTableComparator(field: .title)) { row in
                LibraryCell.title(model.libraryFacts(for: row.entry), selected: isSelected(row.entry))
            }
            .width(min: 200, ideal: 400).customizationID("title").disabledCustomizationBehavior(.visibility)
            TableColumn("Authors", sortUsing: LibraryTableComparator(field: .authors)) { row in
                LibraryCell.text(model.libraryFacts(for: row.entry).authors, label: "Authors", lines: 2)
            }
            .width(min: 100, ideal: 150).customizationID("authors")
            TableColumn("Year", sortUsing: LibraryTableComparator(field: .year)) { row in
                LibraryCell.year(model.libraryFacts(for: row.entry))
            }
            .width(48).customizationID("year")
            TableColumn("Topics") { row in
                LibraryCell.topics(model.libraryFacts(for: row.entry))
            }
            .width(min: 100, ideal: 140).customizationID("topics")
            TableColumn("Added", sortUsing: LibraryTableComparator(field: .recent)) { row in
                LibraryCell.added(model.libraryFacts(for: row.entry))
            }
            .width(78).customizationID("added")
            TableColumn("Opened", sortUsing: LibraryTableComparator(field: .opened)) { row in
                LibraryCell.opened(model.libraryFacts(for: row.entry))
            }
            .width(78).customizationID("opened")
            TableColumn("Read", sortUsing: LibraryTableComparator(field: .progress)) { row in
                LibraryCell.read(model.libraryFacts(for: row.entry))
            }
            .width(86).customizationID("read")
            TableColumn("Chats", sortUsing: LibraryTableComparator(field: .chats)) { row in
                LibraryCell.chats(model.libraryFacts(for: row.entry))
            }
            .width(52).customizationID("chats")
            TableColumn("Pages") { row in
                LibraryCell.text(model.libraryFacts(for: row.entry).pages.map(String.init), label: "Pages").monospacedDigit()
            }
            .width(52).customizationID("pages").defaultVisibility(.hidden)
            TableColumn("Status") { row in
                LibraryCell.status(model.libraryFacts(for: row.entry), getCredits: getCredits)
            }
            .width(min: 100, ideal: 124).customizationID("status").defaultVisibility(anyStatus ? .automatic : .hidden)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let entry = model.libraryRows.first(where: { $0.id == id }) {
                LibraryRowActions(model: model, entry: entry, inTable: true)
            }
        } primaryAction: { ids in
            open(ids)
        }
        .onChange(of: selection) { _, ids in
            // A tap selects the row; opening it is the list's tap. Selection isn't kept.
            guard !ids.isEmpty else { return }
            open(ids)
            selection = []
        }
        .onChange(of: columns) { _, value in LibraryTableSettings.save(value) }
        .accessibilityIdentifier("library.table")
    }

    private var sortOrder: Binding<[LibraryTableComparator]> {
        Binding(get: { [LibraryTableComparator(model.librarySort)] },
                set: { if let first = $0.first { model.librarySort = first.sort } })
    }

    /// The open paper is highlighted only where it is shown beside the table (iPad Browse).
    private func isSelected(_ entry: LibraryListEntry) -> Bool {
        guard model.wideMode == .browse else { return false }
        if case .paper(let paper) = entry { return model.selectedPaper?.id == paper.id }
        return false
    }

    private func open(_ ids: Set<String>) {
        guard ids.count == 1, let id = ids.first,
              case .paper(let paper)? = model.libraryRows.first(where: { $0.id == id }) else { return }
        model.select(paper)
    }
}

/// The phone form of the table (iPhone landscape). SwiftUI's Table shows only its first column on
/// iPhone, so this draws a pinned header of sortable columns over plain rows. The title column
/// carries authors and topics beneath the title; the other columns match the iPad table.
struct LibraryCompactTable: View {
    @Bindable var model: ReaderModel
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

    private enum Column: CaseIterable {
        case year, added, opened, read, chats, status
        var title: String {
            switch self { case .year: "Year"; case .added: "Added"; case .opened: "Opened"; case .read: "Read"; case .chats: "Chats"; case .status: "Status" }
        }
        var field: LibrarySearchSort.Field? {
            switch self { case .year: .year; case .added: .recent; case .opened: .opened; case .read: .progress; case .chats: .chats; case .status: nil }
        }
        var width: CGFloat {
            switch self { case .year: 44; case .added: 70; case .opened: 70; case .read: 80; case .chats: 46; case .status: 108 }
        }
    }

    var body: some View {
        let showStatus = model.libraryRows.contains { model.libraryStatus(for: $0) != .none }
        let columns = Column.allCases.filter { $0 != .status || showStatus }
        List {
            Section {
                ForEach(model.libraryRows) { entry in
                    let facts = model.libraryFacts(for: entry)
                    Group {
                        if case .paper(let paper) = entry {
                            Button { model.select(paper) } label: { row(facts, entry: entry, columns: columns) }.buttonStyle(.plain)
                                .accessibilityIdentifier("library.table.\(entry.id)")
                        } else {
                            row(facts, entry: entry, columns: columns)
                        }
                    }
                    .contextMenu { LibraryRowActions(model: model, entry: entry, inTable: true) }
                    .listRowInsets(EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18))
                }
            } header: {
                header(columns)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("library.table")
    }

    private func header(_ columns: [Column]) -> some View {
        HStack(spacing: 10) {
            headerButton("Title", field: .title).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.self) { column in
                Group {
                    if let field = column.field { headerButton(column.title, field: field) }
                    else { Text(column.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                }
                .frame(width: column.width * scale, alignment: .leading)
            }
        }
        .lineLimit(1).padding(.vertical, 6)
    }

    /// Like the iPad table's headers: tap to sort, tap the current column again to reverse it.
    private func headerButton(_ title: String, field: LibrarySearchSort.Field) -> some View {
        let current = model.librarySort.field == field
        return Button {
            model.librarySort = current ? LibrarySearchSort(field: field, ascending: !model.librarySort.ascending) : LibrarySearchSort(field: field)
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if current {
                    // The same indicator the iPad table draws for its sort direction.
                    Image(systemName: model.librarySort.ascending ? "chevron.down" : "chevron.up").font(.caption2.weight(.bold))
                }
            }
            .frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityValue(current ? (model.librarySort.ascending ? "Sorted ascending" : "Sorted descending") : "")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func row(_ facts: LibraryRowFacts, entry: LibraryListEntry, columns: [Column]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                LibraryCell.title(facts, selected: model.wideMode == .browse && UIDevice.current.userInterfaceIdiom == .pad
                                  && facts.paper.map { model.selectedPaper?.id == $0.id } ?? false)
                let subtitle = ([facts.authors] + [facts.topics.isEmpty ? nil : facts.topics.joined(separator: ", ")]).compactMap { $0 }
                if !subtitle.isEmpty {
                    Text(subtitle.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.self) { column in
                // A ZStack so an empty cell (a ready paper's status) still takes its column's width.
                ZStack(alignment: .leading) {
                    switch column {
                    case .year: LibraryCell.year(facts)
                    case .added: LibraryCell.added(facts)
                    case .opened: LibraryCell.opened(facts)
                    case .read: LibraryCell.read(facts)
                    case .chats: LibraryCell.chats(facts)
                    case .status: LibraryCell.status(facts, getCredits: { model.showStore = true })
                    }
                }
                .frame(width: column.width * scale, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Cells shared by the iPad table and the phone table.
enum LibraryCell {
    static func title(_ facts: LibraryRowFacts, selected: Bool) -> some View {
        Text(facts.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .accessibilityLabel(facts.title)
            .accessibilityIdentifier("library.table.\(facts.id)")
    }

    static func text(_ text: String?, label: String, lines: Int = 1, spoken: String? = nil) -> some View {
        Text(text ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
            .accessibilityLabel(text.map { "\(label): \(spoken ?? $0)" } ?? "")
            .accessibilityHidden(text == nil)
    }

    static func year(_ facts: LibraryRowFacts) -> some View {
        text(facts.year.map(String.init), label: "Year").monospacedDigit()
    }

    static func topics(_ facts: LibraryRowFacts) -> some View {
        text(facts.topics.isEmpty ? nil : facts.topics.joined(separator: ", "), label: "Topics", lines: 2)
    }

    static func added(_ facts: LibraryRowFacts) -> some View {
        text(facts.added.map { LibraryFormat.relativeDay($0) }, label: "Added")
    }

    /// "—" for a paper never opened on this device; imports have no reading activity.
    static func opened(_ facts: LibraryRowFacts) -> some View {
        text(facts.opened.map { LibraryFormat.relativeDay($0) } ?? (facts.paper == nil ? nil : "—"), label: "Opened",
             spoken: facts.opened == nil ? "never" : nil)
    }

    @ViewBuilder static func read(_ facts: LibraryRowFacts) -> some View {
        if let progress = facts.progress {
            let percent = LibraryFormat.percent(progress)
            HStack(spacing: 6) {
                LibraryProgressBar(value: progress).frame(width: 28)
                Text("\(percent)%").font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(percent) percent read")
        } else {
            text(facts.paper == nil ? nil : "—", label: "Read", spoken: "not started")
        }
    }

    static func chats(_ facts: LibraryRowFacts) -> some View {
        text(facts.chats > 0 ? String(facts.chats) : (facts.paper == nil ? nil : "—"), label: "Chats",
             spoken: facts.chats > 0 ? nil : "none").monospacedDigit()
    }

    /// Nothing for a ready paper; otherwise what is happening or what needs attention.
    @ViewBuilder static func status(_ facts: LibraryRowFacts, getCredits: @escaping () -> Void) -> some View {
        switch facts.status {
        case .none: EmptyView()
        case .active(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                step(text, timing: facts.stepTiming)
            }.accessibilityElement(children: .combine)
        case .info(let text):
            step(text, timing: facts.stepTiming)
        case .problem(let text):
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(text).foregroundStyle(.secondary).lineLimit(2) } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).imageScale(.small)
                }.font(.subheadline).labelStyle(LibraryStatusLabelStyle())
                if facts.needsCredits {
                    Button("Get credits", action: getCredits).font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("import.getCredits")
                }
            }
        }
    }

    /// A status, and for an import in progress beneath it how long the step has run ("1 min", then "Taking
    /// longer than usual"), changing once a minute without animation.
    @ViewBuilder private static func step(_ text: String, timing: ImportStepTiming?) -> some View {
        if let timing {
            TimelineView(.periodic(from: timing.since, by: 60)) { context in
                let elapsed = ImportStepElapsed(since: timing.since, now: context.date)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let label = elapsed.label {
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timing.step.spokenStatus(elapsed: elapsed))
            }
        } else {
            Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}


/// Icon and text on the first baseline, tightly spaced.
struct LibraryStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) { configuration.icon.accessibilityHidden(true); configuration.title }
    }
}

/// A small reading-progress bar for the Read column.
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

/// "Detailed rows": the narrow form of the table layout. Title, then authors · year · topics,
/// then this device's activity; unknown facts are left out rather than printed blank.
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
