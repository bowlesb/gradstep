import SwiftUI

// A table of papers drawn by the app (owner request 2026-10-06: "a sane true table view of papers that we can
// re-use for the feed"). It is the same table on every size: a header of column titles (tap to sort, tap again to
// reverse), one aligned row per paper, and as many columns beside the title as fit the width — never a horizontal
// scroll. SwiftUI's `Table` collapses to one column in compact width, so this is built from a plain List, which
// also gives the rows long-press menus, swipe actions, pull to refresh and a header that stays pinned.

/// One column beside the title. Which columns show depends on the width (see `PaperTableLayout`).
struct PaperTableColumn<Key: Hashable>: Identifiable {
    let id: String
    let title: String
    /// 0 is the most important. Columns appear in priority order while they fit.
    var priority = 0
    /// Width at the default text size; it grows with Dynamic Type.
    var width: CGFloat = 0
    var alignment: Alignment = .leading
    /// Tapping the header sorts by this key, first in `ascendingFirst` direction.
    var sortKey: Key? = nil
    var ascendingFirst = false
    /// A control (Add) rather than a value: outside the row's tap area, and not read as part of the row.
    var isControl = false
}

/// The current order: which key, which direction.
struct PaperTableSort<Key: Hashable>: Equatable {
    var key: Key
    var ascending: Bool

    /// A header tap: the current column reverses; another column starts in its natural direction.
    func tapping(_ column: PaperTableColumn<Key>) -> Self {
        guard let tapped = column.sortKey else { return self }
        return tapped == key ? Self(key: key, ascending: !ascending) : Self(key: tapped, ascending: column.ascendingFirst)
    }
}

extension PaperTableColumn: Sendable where Key: Sendable {}
extension PaperTableSort: Sendable where Key: Sendable {}

/// Which columns fit. Pure, so it is tested with injected widths.
enum PaperTableLayout {
    /// Between columns (the design's 12 pt step).
    static let spacing: CGFloat = 12
    /// The title column never gets narrower than this (scaled with text size)…
    static let titleMinimum: CGFloat = 160
    /// …nor, on wide screens, than this share of the row, so extra columns don't squeeze titles to a few words.
    static let titleShare: CGFloat = 0.34

    static func titleWidth(in width: CGFloat, scale: CGFloat) -> CGFloat { max(titleMinimum * scale, width * titleShare) }

    /// The columns shown in a row `width` wide (inside the margins), in their declared order. Columns are taken in
    /// priority order until the next one doesn't fit, so a wider screen only ever adds columns.
    static func visibleColumns<Key>(_ columns: [PaperTableColumn<Key>], width: CGFloat, scale: CGFloat = 1) -> [PaperTableColumn<Key>] {
        var used = titleWidth(in: width, scale: scale)
        var shown = Set<String>()
        let byPriority = columns.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
        for (_, column) in byPriority {
            let next = used + spacing + column.width * scale
            guard next <= width else { break }
            used = next
            shown.insert(column.id)
        }
        return columns.filter { shown.contains($0.id) }
    }
}

/// The title cell: the title (two lines) and under it, muted, the first author.
struct PaperTableTitle {
    let title: String
    var subtitle: String? = nil
    /// The open paper where it is shown beside the table (iPad Browse).
    var highlighted = false
}

/// A row's tap: what it does, and what VoiceOver says it does.
struct PaperTableAction {
    let hint: String
    let perform: () -> Void
}

struct PaperTable<Row: Identifiable, Key: Hashable, Cell: View, Actions: View, Swipe: View, Detail: View, Top: View>: View {
    let rows: [Row]
    let titleColumn: PaperTableColumn<Key>
    let columns: [PaperTableColumn<Key>]
    @Binding var sort: PaperTableSort<Key>
    /// Accessibility identifier of the table; rows use `rowIdentifier`.
    let identifier: String
    let rowIdentifier: (Row) -> String
    let title: (Row) -> PaperTableTitle
    let cell: (Row, String) -> Cell
    /// What VoiceOver reads for a column of a row ("Added today"); nil reads nothing.
    let spoken: (Row, String) -> String?
    /// The row's tap; nil when the row has none.
    let primaryAction: (Row) -> PaperTableAction?
    /// Long-press actions.
    let menu: (Row) -> Actions
    let swipe: (Row) -> Swipe
    /// Shown under a row (the Feed's abstract when a row is opened).
    let detail: (Row) -> Detail
    /// Scrolls above the header (status banners).
    let top: () -> Top
    var pinnedHeader = true
    /// Names of orders that have no column (the Library's Authors), for the header's sort indicator.
    var extraSortTitles: [Key: String] = [:]

    init(rows: [Row], titleColumn: PaperTableColumn<Key>, columns: [PaperTableColumn<Key>], sort: Binding<PaperTableSort<Key>>,
         extraSortTitles: [Key: String] = [:],
         identifier: String, pinnedHeader: Bool = true, rowIdentifier: @escaping (Row) -> String,
         title: @escaping (Row) -> PaperTableTitle, @ViewBuilder cell: @escaping (Row, String) -> Cell,
         spoken: @escaping (Row, String) -> String?, primaryAction: @escaping (Row) -> PaperTableAction?,
         @ViewBuilder menu: @escaping (Row) -> Actions, @ViewBuilder swipe: @escaping (Row) -> Swipe,
         @ViewBuilder detail: @escaping (Row) -> Detail, @ViewBuilder top: @escaping () -> Top) {
        self.rows = rows; self.titleColumn = titleColumn; self.columns = columns; self._sort = sort
        self.extraSortTitles = extraSortTitles
        self.identifier = identifier; self.pinnedHeader = pinnedHeader; self.rowIdentifier = rowIdentifier
        self.title = title; self.cell = cell; self.spoken = spoken; self.primaryAction = primaryAction
        self.menu = menu; self.swipe = swipe; self.detail = detail; self.top = top
    }

    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row width inside the margins, measured on the header (rows share its insets).
    @State private var width: CGFloat = 0

    private static var rowInsets: EdgeInsets {
        EdgeInsets(top: 10, leading: DesignMetrics.margin, bottom: 10, trailing: DesignMetrics.margin)
    }

    var body: some View {
        let visible = PaperTableLayout.visibleColumns(columns, width: width, scale: scale)
        List {
            Section {
                top()
                // An empty first section leaves the plain list's header padding (22 pt) above the column header.
                Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).accessibilityHidden(true)
            }
            Section {
                if !pinnedHeader { header(visible) }
                ForEach(rows) { row in
                    rowView(row, visible: visible)
                        .frame(minHeight: 44)
                        .listRowInsets(Self.rowInsets)
                        .contextMenu { menu(row) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipe(row) }
                }
            } header: {
                if pinnedHeader { header(visible) }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Header

    private func header(_ visible: [PaperTableColumn<Key>]) -> some View {
        HStack(alignment: .center, spacing: PaperTableLayout.spacing) {
            HStack(spacing: 6) {
                headerCell(titleColumn)
                hiddenSortIndicator(visible)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(visible) { column in
                headerCell(column).frame(width: column.width * scale, alignment: column.alignment)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: DesignMetrics.margin, bottom: 0, trailing: DesignMetrics.margin))
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
    }

    private static var headerColor: Color { Color(uiColor: .secondaryLabel) }

    @ViewBuilder private func headerCell(_ column: PaperTableColumn<Key>) -> some View {
        if column.sortKey != nil {
            let current = column.sortKey == sort.key
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { sort = sort.tapping(column) }
            } label: {
                HStack(spacing: 3) {
                    Text(column.title).lineLimit(1)
                    if current { chevron }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(current ? Color.accentColor : Self.headerColor)
                .frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(column.title)
            .accessibilityValue(current ? (sort.ascending ? "Sorted ascending" : "Sorted descending") : "")
            .accessibilityHint(current ? "Reverses the order" : "Sorts by this column")
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).header.\(column.id)")
        } else {
            Text(column.title).font(.footnote.weight(.semibold)).foregroundStyle(Self.headerColor).lineLimit(1)
                .frame(minHeight: 36)
                .accessibilityHidden(column.title.isEmpty)
                .accessibilityIdentifier("\(identifier).header.\(column.id)")
        }
    }

    private var chevron: some View {
        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
    }

    /// The order still shows when its column is too wide to fit (phone portrait sorted by Added) or has no column
    /// (Authors): "· Added ⌄" beside Title; tapping it reverses the order.
    @ViewBuilder private func hiddenSortIndicator(_ visible: [PaperTableColumn<Key>]) -> some View {
        let shown = [titleColumn.sortKey] + visible.map(\.sortKey)
        if !shown.contains(sort.key), let name = columns.first(where: { $0.sortKey == sort.key })?.title ?? extraSortTitles[sort.key] {
            Text("·").font(.footnote.weight(.semibold)).foregroundStyle(Self.headerColor).accessibilityHidden(true)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { sort.ascending.toggle() }
            } label: {
                HStack(spacing: 3) { Text(name).lineLimit(1); chevron }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sorted by \(name)")
            .accessibilityValue(sort.ascending ? "Ascending" : "Descending")
            .accessibilityHint("Reverses the order")
            .accessibilityIdentifier("\(identifier).sortIndicator")
        }
    }

    // MARK: Rows

    private func rowView(_ row: Row, visible: [PaperTableColumn<Key>]) -> some View {
        let values = visible.filter { !$0.isControl }
        let controls = visible.filter(\.isControl)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: PaperTableLayout.spacing) {
                tappable(row) {
                    HStack(alignment: .firstTextBaseline, spacing: PaperTableLayout.spacing) {
                        PaperTableTitleCell(title: title(row)).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(values) { column in
                            cell(row, column.id).frame(width: column.width * scale, alignment: column.alignment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                ForEach(controls) { column in
                    cell(row, column.id).frame(width: column.width * scale, alignment: column.alignment)
                }
            }
            detail(row)
        }
    }

    /// The row as one element: title, subtitle and every column's value (including columns too wide to show).
    @ViewBuilder private func tappable<Content: View>(_ row: Row, @ViewBuilder content: () -> Content) -> some View {
        let label = ([title(row).title, title(row).subtitle] + columns.filter { !$0.isControl }.map { spoken(row, $0.id) })
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if let action = primaryAction(row) {
            Button(action: action.perform, label: content).buttonStyle(.plain)
                .accessibilityLabel(label).accessibilityHint(action.hint)
                .accessibilityIdentifier(rowIdentifier(row))
        } else {
            content()
                .accessibilityElement(children: .ignore).accessibilityLabel(label)
                .accessibilityIdentifier(rowIdentifier(row))
        }
    }
}

/// Title, then the first author, muted. Truncated at the end rather than broken mid-word.
struct PaperTableTitleCell: View {
    let title: PaperTableTitle
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.title).font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.tail)
                .foregroundStyle(title.highlighted ? Color.accentColor : .primary)
            if let subtitle = title.subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// A plain value cell: secondary text on one line, digits aligned; nothing for an unknown value.
struct PaperTableText: View {
    let text: String?
    var body: some View {
        Text(text ?? "").font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
    }
}
