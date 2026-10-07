import SwiftUI

// A table of papers drawn by the app (owner request 2026-10-06: "a sane true table view of papers that we can
// re-use for the feed"). It is the same table on every size: a header of column titles (tap to sort, tap again to
// reverse), one aligned row per paper, and as many columns beside the title as fit the width — never a horizontal
// scroll. SwiftUI's `Table` collapses to one column in compact width, so this is built from a plain List, which
// also gives the rows long-press menus, swipe actions, pull to refresh and a header that stays pinned. The caller
// passes the columns the reader chose (owner request 2026-10-07); rows get a hover fill and arrow-key navigation.

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
    /// The title column never gets narrower than this (scaled with text size): room for Progress and any one short
    /// column on the smallest phone, and for Progress alone in the iPad's Browse column…
    static let titleMinimum: CGFloat = 155
    /// …nor than this share of the row, so extra columns don't squeeze titles to a few words (a Pro Max in portrait
    /// keeps two columns, like the other phones).
    static let titleShare: CGFloat = 0.4

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
    /// The columns that may show (the reader's choice); those that fit the width are shown.
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
    /// Shown under a row (the Feed's abstract when a row is opened); given the IDs of the columns shown.
    let detail: (Row, Set<String>) -> Detail
    /// Scrolls above the header (status banners, filters).
    let top: () -> Top
    var pinnedHeader = true
    /// Names of orders that have no column (the Library's Authors), for the header's sort indicator.
    var extraSortTitles: [Key: String] = [:]
    /// A cell that holds a control for this row (a failed import's Retry): it sits outside the row's tap area and
    /// isn't read as part of the row, like a column marked `isControl`. Only trailing cells should be controls.
    var cellIsControl: (Row, String) -> Bool = { _, _ in false }

    init(rows: [Row], titleColumn: PaperTableColumn<Key>, columns: [PaperTableColumn<Key>], sort: Binding<PaperTableSort<Key>>,
         extraSortTitles: [Key: String] = [:],
         identifier: String, pinnedHeader: Bool = true, rowIdentifier: @escaping (Row) -> String,
         title: @escaping (Row) -> PaperTableTitle, @ViewBuilder cell: @escaping (Row, String) -> Cell,
         cellIsControl: @escaping (Row, String) -> Bool = { _, _ in false },
         spoken: @escaping (Row, String) -> String?, primaryAction: @escaping (Row) -> PaperTableAction?,
         @ViewBuilder menu: @escaping (Row) -> Actions, @ViewBuilder swipe: @escaping (Row) -> Swipe,
         @ViewBuilder detail: @escaping (Row, Set<String>) -> Detail, @ViewBuilder top: @escaping () -> Top) {
        self.rows = rows; self.titleColumn = titleColumn; self.columns = columns; self._sort = sort
        self.extraSortTitles = extraSortTitles
        self.identifier = identifier; self.pinnedHeader = pinnedHeader; self.rowIdentifier = rowIdentifier
        self.title = title; self.cell = cell; self.cellIsControl = cellIsControl; self.spoken = spoken
        self.primaryAction = primaryAction
        self.menu = menu; self.swipe = swipe; self.detail = detail; self.top = top
    }

    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row width inside the margins, measured on the header (rows share its insets).
    @State private var width: CGFloat = 0
    /// The row under the pointer (iPad, Mac).
    @State private var hovered: Row.ID?
    /// The row chosen with the arrow keys (hardware keyboard); Return opens it.
    @State private var keyboardRow: Row.ID?
    @FocusState private var focused: Bool

    private static var rowInsets: EdgeInsets {
        EdgeInsets(top: 10, leading: DesignMetrics.margin, bottom: 10, trailing: DesignMetrics.margin)
    }

    var body: some View {
        let visible = PaperTableLayout.visibleColumns(columns, width: width, scale: scale)
        let visibleIDs = Set(visible.map(\.id))
        ScrollViewReader { proxy in
            List {
                Section {
                    top()
                    // An empty first section leaves the plain list's header padding (22 pt) above the column header.
                    Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).accessibilityHidden(true)
                }
                Section {
                    if !pinnedHeader { header(visible) }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            rowView(row, visible: visible)
                            detail(row, visibleIDs)
                        }
                        .frame(minHeight: 44)
                        .listRowInsets(Self.rowInsets)
                        .listRowBackground(rowBackground(row))
                        .onHover { inside in
                            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                        }
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
            // Hardware keyboard (iPad, Mac): ↑/↓ choose a row, Return opens it, Escape lets go.
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveKeyboardRow(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { moveKeyboardRow(by: -1, proxy: proxy) }
            .onKeyPress(.return) {
                guard let id = keyboardRow, let row = rows.first(where: { $0.id == id }), let action = primaryAction(row) else { return .ignored }
                action.perform(); return .handled
            }
            .onKeyPress(.escape) {
                guard keyboardRow != nil else { return .ignored }
                keyboardRow = nil; return .handled
            }
            .onAppear { focused = true }
            .onChange(of: rows.map(\.id)) { _, ids in if let id = keyboardRow, !ids.contains(id) { keyboardRow = nil } }
        }
        .accessibilityIdentifier(identifier)
    }

    /// The keyboard's row, else the hovered one, gets a quiet fill (the selection color for the keyboard).
    private func rowBackground(_ row: Row) -> Color? {
        if keyboardRow == row.id { return Color.accentColor.opacity(focused ? 0.14 : 0.08) }
        if hovered == row.id { return Color.primary.opacity(0.05) }   // as `macRowHover()`, on iPad too
        return nil
    }

    private func moveKeyboardRow(by step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = keyboardRow.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { min(rows.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : rows.count - 1)
        keyboardRow = rows[next].id
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(rows[next].id) }
        return .handled
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
        // Values are part of the row's tap; from the first control on, cells sit outside it (at the trailing end).
        let firstControl = visible.firstIndex { $0.isControl || cellIsControl(row, $0.id) } ?? visible.endIndex
        let values = Array(visible[..<firstControl])
        let controls = Array(visible[firstControl...])
        return HStack(alignment: .firstTextBaseline, spacing: PaperTableLayout.spacing) {
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

/// Tags as small chips that wrap within the cell, at most two lines (the owner's web library showed keyword chips).
/// A chip matching the active tag filter is drawn in the accent color.
struct PaperTableChips: View {
    let tags: [String]
    var highlighted: String? = nil
    var body: some View {
        PaperTableChipFlow(spacing: 4, lineSpacing: 4, maxLines: 2) {
            ForEach(tags, id: \.self) { tag in
                let on = tag == highlighted
                Text(tag).font(.caption.weight(on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(on ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
        }
        .clipped()
        .accessibilityHidden(true)   // the row reads its tags
    }
}

/// Lays chips out left to right, wrapping, up to `maxLines`; chips beyond that are left out of view.
struct PaperTableChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var maxLines: Int

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var lines: [[(index: Int, size: CGSize)]] = [], line: [(index: Int, size: CGSize)] = [], used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !line.isEmpty, used + spacing + size.width > width {
                lines.append(line); line = []; used = 0
            }
            used += (line.isEmpty ? 0 : spacing) + size.width
            line.append((index, size))
        }
        if !line.isEmpty { lines.append(line) }
        return Array(lines.prefix(maxLines))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let shown = lines(subviews, width: proposal.width ?? .infinity)
        var height: CGFloat = 0, widest: CGFloat = 0
        for (number, line) in shown.enumerated() {
            var lineHeight: CGFloat = 0, lineWidth: CGFloat = 0
            for (position, item) in line.enumerated() {
                lineHeight = max(lineHeight, item.size.height)
                lineWidth += (position == 0 ? 0 : spacing) + item.size.width
            }
            height += (number == 0 ? 0 : lineSpacing) + lineHeight
            widest = max(widest, lineWidth)
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    /// The first chip's baseline, so the cell lines up with the row's first line of text.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = lines(subviews, width: bounds.width).first?.first else { return nil }
        return bounds.minY + subviews[first.index].dimensions(in: ProposedViewSize(first.size))[VerticalAlignment.firstTextBaseline]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var placed = Set<Int>(), y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                placed.insert(item.index); x += item.size.width + spacing
            }
            y += (line.map(\.size.height).max() ?? 0) + lineSpacing
        }
        // Chips past the last line go outside the (clipped) cell.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 10_000), proposal: .zero)
        }
    }
}
