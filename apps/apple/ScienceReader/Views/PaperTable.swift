import SwiftUI

// A table of papers drawn by the app (owner request 2026-10-06: "a sane true table view of papers that we can
// re-use for the feed"). It is the same table on every size: a header of column titles (tap to sort, tap again to
// reverse), one aligned row per paper, and the chosen columns beside a pinned title, scrolling sideways when needed.
// SwiftUI's `Table` collapses to one column in compact width, so this is built from a plain List, which
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
        let shown = TableArrangement.fit(columns.map(item), rowWidth: width, titleMinimum: titleMinimum, titleShare: titleShare,
                                         spacing: spacing, scale: scale)
        return columns.filter { shown.contains($0.id) }
    }

    /// Every chosen column, scrolling sideways when they don't all fit (controls such as Add stay pinned at the end).
    static func arrangement<Key>(_ columns: [PaperTableColumn<Key>], width: CGFloat, scale: CGFloat = 1, scrolling: Bool) -> TableArrangement {
        TableArrangement.make(columns.map(item), rowWidth: width, titleMinimum: titleMinimum, titleShare: titleShare,
                              spacing: spacing, scale: scale, scrolling: scrolling)
    }

    private static func item<Key>(_ column: PaperTableColumn<Key>) -> TableArrangement.Item {
        TableArrangement.Item(id: column.id, priority: column.priority, width: column.width, pinned: column.isControl)
    }
}

// MARK: - Horizontal scrolling (owner feedback, build 16 #3: "choose which columns to show and also allow horizontal
// scrolling")

/// Where a table's columns sit in a row. When every chosen column fits, as before: the title takes what is left and the
/// columns follow in their order. When they don't, the title stays pinned at the leading edge (and pinned columns —
/// a control such as Add, or All chats' Last used — at the trailing edge), and the rest sit in a region between them
/// that scrolls sideways: first the columns that fit there, in their order (so the table looks as it did before
/// scrolling), then the others. Pure, so it is tested with injected widths.
struct TableArrangement: Equatable {
    struct Item: Equatable {
        var id: String
        var priority: Int
        /// At the default text size.
        var width: CGFloat
        /// Stays at the trailing edge while the others scroll.
        var pinned = false
    }

    /// The columns in the region (all shown columns when the table doesn't scroll), in display order.
    var columns: [String]
    /// The columns pinned at the trailing edge (only while scrolling).
    var pinned: [String] = []
    /// The title's width while scrolling; nil when it takes what is left.
    var titleWidth: CGFloat? = nil
    /// How wide the scrolling region is, and how far its columns scroll.
    var regionWidth: CGFloat = 0
    var extent: CGFloat = 0
    var snapOffsets: [CGFloat] = [0]
    var scrolls: Bool { extent > 0.5 }
    /// A single wide chosen column can fit after narrowing to its viewport. It still uses the fixed title/action
    /// layout even when there is no distance to scroll.
    var usesColumnRegion: Bool { titleWidth != nil }

    /// A value always fits its viewport; wide text wraps/truncates inside its cell instead of being permanently
    /// hidden behind the pinned title or action. The row's expanded abstract still shows its full text.
    func columnWidth(_ preferred: CGFloat) -> CGFloat { usesColumnRegion ? min(preferred, regionWidth) : preferred }

    /// The narrowest region worth scrolling in, when only the title and pinned columns would fit.
    static let regionMinimum: CGFloat = 90

    static func make(_ items: [Item], rowWidth: CGFloat, titleMinimum: CGFloat, titleShare: CGFloat, spacing: CGFloat,
                     scale: CGFloat, scrolling: Bool) -> TableArrangement {
        let fitting = fit(items, rowWidth: rowWidth, titleMinimum: titleMinimum, titleShare: titleShare, spacing: spacing, scale: scale)
        let free = items.filter { !$0.pinned }
        guard scrolling, rowWidth > 0, free.contains(where: { !fitting.contains($0.id) }) else {
            return TableArrangement(columns: items.filter { fitting.contains($0.id) }.map(\.id))
        }
        let pinned = items.filter(\.pinned)
        let order = free.filter { fitting.contains($0.id) } + free.filter { !fitting.contains($0.id) }
        let pinnedWidth = pinned.reduce(0) { $0 + $1.width * scale + spacing }
        let title = max(0, min(max(titleMinimum * scale, rowWidth * titleShare),
                               rowWidth - pinnedWidth - spacing - regionMinimum * scale))
        let region = max(0, rowWidth - pinnedWidth - spacing - title)
        let widths = order.map { min($0.width * scale, region) }
        let content = widths.reduce(0, +) + spacing * CGFloat(max(0, order.count - 1))
        let extent = max(0, content - region)
        var offsets: [CGFloat] = [0], start: CGFloat = 0
        for value in widths.dropLast() {
            start += value + spacing
            if start < extent { offsets.append(start) }
        }
        if extent > 0 { offsets.append(extent) }
        return TableArrangement(columns: order.map(\.id), pinned: pinned.map(\.id), titleWidth: title,
                                regionWidth: region, extent: extent, snapOffsets: offsets)
    }

    /// The columns that fit beside the title, taken by priority until the next one doesn't (`PaperTableLayout`).
    static func fit(_ items: [Item], rowWidth: CGFloat, titleMinimum: CGFloat, titleShare: CGFloat, spacing: CGFloat,
                    scale: CGFloat) -> Set<String> {
        var used = max(titleMinimum * scale, rowWidth * titleShare)
        var shown = Set<String>()
        for (_, item) in items.enumerated().sorted(by: { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }) {
            let next = used + spacing + item.width * scale
            guard next <= rowWidth else { break }
            used = next
            shown.insert(item.id)
        }
        return shown
    }
}

/// How far a table's columns have scrolled sideways. Only the views that move read it, so a scroll doesn't redraw the
/// table.
@MainActor @Observable final class TableScrollState {
    var x: CGFloat = 0
}

/// A table's List inside a sideways scroll view, for tables whose columns can be wider than the screen. The List stays
/// where it is (it moves back by what the scroll view moved), so its rows, header, pull to refresh and vertical scrolling
/// are as before; only the column regions (`TableScrollRegion`) move. With nothing to scroll it is disabled, so row swipe
/// actions and everything else behave as without it.
struct HorizontalTableScroll<Content: View>: View {
    let state: TableScrollState
    let extent: CGFloat
    var snapOffsets: [CGFloat] = [0]
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            content
                // The scroll view's own disabling must not reach the List's vertical scrolling.
                .environment(\.isScrollEnabled, true)
                .containerRelativeFrame(.horizontal)
                .modifier(TableCounterOffset(state: state))
                .padding(.trailing, extent)
                .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView(axis: .horizontal)).minX } action: { state.x = $0 }
        }
        .scrollIndicators(.hidden, axes: .horizontal)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollTargetBehavior(TableColumnSnapBehavior(offsets: snapOffsets))
        .scrollDisabled(extent <= 0.5)
    }
}

/// A swipe lands at a column boundary, so a header and its values can be read together. This changes only sideways
/// scroll settling; the List still owns vertical momentum and pull to refresh.
private struct TableColumnSnapBehavior: ScrollTargetBehavior {
    let offsets: [CGFloat]
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard let offset = offsets.min(by: { abs($0 - target.rect.minX) < abs($1 - target.rect.minX) }) else { return }
        target.rect.origin.x = offset
    }
}

private struct TableCounterOffset: ViewModifier {
    let state: TableScrollState
    func body(content: Content) -> some View { content.offset(x: state.x) }
}

/// A row's (or the header's) scrolling columns: moved by the table's sideways scroll, clipped to the region, with a
/// short fade at an edge that has more columns past it.
struct TableScrollRegion<Content: View>: View {
    let state: TableScrollState
    let width: CGFloat
    let extent: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let x = min(max(0, state.x), extent)
        content
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -x)
            .frame(width: max(0, width), alignment: .leading)
            .clipped()
            .mask(HStack(spacing: 0) {
                LinearGradient(colors: [x > 1 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                Color.black
                LinearGradient(colors: [.black, x < extent - 1 ? .clear : .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
            })
    }
}

/// The title cell: the title (two lines) and under it, muted, the first author.
struct PaperTableTitle {
    let title: String
    var subtitle: String? = nil
    /// The open paper where it is shown beside the table (iPad Browse).
    var highlighted = false
    var expanded = false
    /// Lines the second line may take (the Feed's "why" line needs two).
    var subtitleLines = 1
    /// What this device holds of the paper, shown as a small symbol after the title (Library rows).
    var deviceCopy: PaperDeviceCopy? = nil
    /// Tapping the cloud symbol downloads the paper to this device (Library rows).
    var download: (() -> Void)? = nil
    /// A paper still being added: the row keeps the height it will have once its title and authors arrive (two title
    /// lines and the authors' line), so it doesn't grow midway (owner, build 58).
    var reservesSpace = false
    var reservesSubtitleSpace = true
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
    /// Every chosen column shows, scrolling sideways when they don't fit (`TableArrangement`); otherwise only those
    /// that fit show.
    var horizontalScroll = false
    var rowAlignment: VerticalAlignment = .firstTextBaseline

    init(rows: [Row], titleColumn: PaperTableColumn<Key>, columns: [PaperTableColumn<Key>], sort: Binding<PaperTableSort<Key>>,
         extraSortTitles: [Key: String] = [:], horizontalScroll: Bool = false, rowAlignment: VerticalAlignment = .firstTextBaseline,
         identifier: String, pinnedHeader: Bool = true, rowIdentifier: @escaping (Row) -> String,
         title: @escaping (Row) -> PaperTableTitle, @ViewBuilder cell: @escaping (Row, String) -> Cell,
         cellIsControl: @escaping (Row, String) -> Bool = { _, _ in false },
         spoken: @escaping (Row, String) -> String?, primaryAction: @escaping (Row) -> PaperTableAction?,
         @ViewBuilder menu: @escaping (Row) -> Actions, @ViewBuilder swipe: @escaping (Row) -> Swipe,
         @ViewBuilder detail: @escaping (Row, Set<String>) -> Detail, @ViewBuilder top: @escaping () -> Top) {
        self.rows = rows; self.titleColumn = titleColumn; self.columns = columns; self._sort = sort
        self.extraSortTitles = extraSortTitles; self.horizontalScroll = horizontalScroll
        self.rowAlignment = rowAlignment
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
    @State private var scroll = TableScrollState()

    private static var rowInsets: EdgeInsets {
        EdgeInsets(top: 10, leading: DesignMetrics.margin, bottom: 10, trailing: DesignMetrics.margin)
    }

    var body: some View {
        let arrangement = PaperTableLayout.arrangement(columns, width: width, scale: scale, scrolling: horizontalScroll)
        if horizontalScroll {
            HorizontalTableScroll(state: scroll, extent: arrangement.extent, snapOffsets: arrangement.snapOffsets) { table(arrangement) }
                .accessibilityIdentifier(identifier)
        } else {
            table(arrangement).accessibilityIdentifier(identifier)
        }
    }

    private func columns(_ ids: [String]) -> [PaperTableColumn<Key>] {
        ids.compactMap { id in columns.first { $0.id == id } }
    }

    private func table(_ arrangement: TableArrangement) -> some View {
        let visible = columns(arrangement.columns) + columns(arrangement.pinned)
        let visibleIDs = Set(visible.map(\.id))
        return ScrollViewReader { proxy in
            List {
                Section {
                    top()
                    // An empty first section leaves the plain list's header padding (22 pt) above the column header.
                    Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).accessibilityHidden(true)
                }
                Section {
                    if !pinnedHeader { header(arrangement) }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            if arrangement.usesColumnRegion { scrollingRow(row, arrangement) } else { rowView(row, visible: visible) }
                            detail(row, visibleIDs)
                        }
                        .frame(minHeight: 44)
                        .listRowInsets(Self.rowInsets)
                        .listRowBackground(rowBackground(row))
                        .onHover { inside in
                            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                        }
                        .contextMenu { menu(row) }
                        // A sideways swipe scrolls the columns while they scroll; the row's actions stay in its menu.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { if !arrangement.scrolls { swipe(row) } }
                    }
                } header: {
                    if pinnedHeader { header(arrangement) }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .environment(\.defaultMinListHeaderHeight, 0)
            .environment(\.defaultMinListRowHeight, 0)
            // Hardware keyboard (iPad, Mac): ↑/↓ choose a row, Return opens it. Key commands rather than focus, so
            // they work as soon as the table shows; a focused text field (search) keeps its own keys.
            .background { keyCommands(proxy) }
            .onChange(of: rows.map(\.id)) { _, ids in if let id = keyboardRow, !ids.contains(id) { keyboardRow = nil } }
        }
    }

    private func keyCommands(_ proxy: ScrollViewProxy) -> some View {
        Group {
            Button("Next paper") { moveKeyboardRow(by: 1, proxy: proxy) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Previous paper") { moveKeyboardRow(by: -1, proxy: proxy) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Open") {
                guard let id = keyboardRow, let row = rows.first(where: { $0.id == id }) else { return }
                primaryAction(row)?.perform()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(keyboardRow == nil)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// The keyboard's row, else the hovered one, gets a quiet fill (the selection color for the keyboard).
    private func rowBackground(_ row: Row) -> Color? {
        if keyboardRow == row.id { return Color.accentColor.opacity(0.14) }
        if hovered == row.id { return Color.primary.opacity(0.05) }   // as `macRowHover()`, on iPad too
        return nil
    }

    private func moveKeyboardRow(by step: Int, proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let index = keyboardRow.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { min(rows.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : rows.count - 1)
        keyboardRow = rows[next].id
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(rows[next].id) }
    }

    // MARK: Header

    private func header(_ arrangement: TableArrangement) -> some View {
        let visible = columns(arrangement.columns), pinned = columns(arrangement.pinned)
        return HStack(alignment: .center, spacing: PaperTableLayout.spacing) {
            HStack(spacing: 6) {
                headerCell(titleColumn)
                hiddenSortIndicator(PaperTableLayout.visibleColumns(columns, width: width, scale: scale))
            }
            .frame(maxWidth: arrangement.titleWidth ?? .infinity, alignment: .leading)
            .frame(width: arrangement.titleWidth, alignment: .leading)
            if arrangement.usesColumnRegion {
                TableScrollRegion(state: scroll, width: arrangement.regionWidth, extent: arrangement.extent) {
                    HStack(alignment: .center, spacing: PaperTableLayout.spacing) {
                        ForEach(visible) { column in
                            headerCell(column).frame(width: arrangement.columnWidth(column.width * scale), alignment: column.alignment)
                        }
                    }
                }
                ForEach(pinned) { column in
                    headerCell(column).frame(width: column.width * scale, alignment: column.alignment)
                }
            } else {
                ForEach(visible) { column in
                    headerCell(column).frame(width: column.width * scale, alignment: column.alignment)
                }
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
        return HStack(alignment: rowAlignment, spacing: PaperTableLayout.spacing) {
            tappable(row) {
                HStack(alignment: rowAlignment, spacing: PaperTableLayout.spacing) {
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

    /// A row while the columns scroll: the title (the row's element for VoiceOver), the scrolling columns (values tap
    /// like the row; a control such as Retry is its own element), then the pinned columns.
    private func scrollingRow(_ row: Row, _ arrangement: TableArrangement) -> some View {
        HStack(alignment: rowAlignment, spacing: PaperTableLayout.spacing) {
            tappable(row) {
                PaperTableTitleCell(title: title(row)).frame(width: arrangement.titleWidth ?? 0, alignment: .leading).contentShape(Rectangle())
            }
            TableScrollRegion(state: scroll, width: arrangement.regionWidth, extent: arrangement.extent) {
                HStack(alignment: rowAlignment, spacing: PaperTableLayout.spacing) {
                    ForEach(columns(arrangement.columns)) { column in
                        scrollingCell(row, column, width: arrangement.columnWidth(column.width * scale))
                    }
                }
            }
            ForEach(columns(arrangement.pinned)) { column in
                cell(row, column.id).frame(width: column.width * scale, alignment: column.alignment)
            }
        }
    }

    @ViewBuilder private func scrollingCell(_ row: Row, _ column: PaperTableColumn<Key>, width: CGFloat) -> some View {
        let value = cell(row, column.id).frame(width: width, alignment: column.alignment)
        if column.isControl || cellIsControl(row, column.id) {
            value
        } else if let action = primaryAction(row) {
            // Part of the row's tap; VoiceOver reads it with the row (on the title).
            Button(action: action.perform) { value.contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityHidden(true)
        } else {
            value.accessibilityHidden(true)
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
        let placeholder = title.reservesSpace && title.subtitle == nil && title.deviceCopy == nil
        ZStack(alignment: .leading) {
        VStack(alignment: .leading, spacing: 2) {
            // One line limit: an expanded title is whole; a row being added keeps two lines' room.
            Text(title.title).font(.subheadline.weight(.semibold))
                .modifier(TitleLines(expanded: title.expanded, reservesSpace: title.reservesSpace)).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(title.highlighted ? Color.accentColor : .primary)
            // A Library row's second line is always the cloud button's height (24 pt), so a row doesn't change height as
            // a paper is added, downloaded and opened (owner, builds 58–59).
            let libraryLine: CGFloat? = title.deviceCopy != nil || title.reservesSpace ? 24 : nil
            if title.reservesSpace && title.reservesSubtitleSpace && title.subtitle == nil && title.deviceCopy == nil {
                Text(" ").font(.footnote).frame(minHeight: libraryLine).accessibilityHidden(true)
            }
            if title.subtitle != nil || title.deviceCopy != nil {
                HStack(spacing: 5) {
                    if let copy = title.deviceCopy {
                        let symbol = Image(systemName: copy.symbol).font(.caption2.weight(.semibold))
                            .foregroundStyle(copy == .reader || copy == .pdf ? Color.accentColor : copy == .unavailable ? Color.orange : Color.secondary)
                        if copy == .cloud, let download = title.download {
                            Button(action: download) { symbol.frame(minWidth: 28, minHeight: 24) }.buttonStyle(.plain)
                                .accessibilityLabel("Download to this device").help("Download to this device")
                        } else {
                            symbol.accessibilityLabel(copy.label).help(copy.label)
                        }
                    }
                    if let subtitle = title.subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(title.subtitleLines).truncationMode(.tail)
                    }
                }
                .frame(minHeight: libraryLine)
            }
        }
        .opacity(placeholder ? 0 : 1).accessibilityHidden(placeholder)
        if placeholder {
            Text(title.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
    }
}

private struct TitleLines: ViewModifier {
    let expanded: Bool
    let reservesSpace: Bool
    func body(content: Content) -> some View {
        if expanded { content.lineLimit(nil) } else { content.lineLimit(2, reservesSpace: reservesSpace) }
    }
}

/// A plain value cell: secondary text on one line, digits aligned; nothing for an unknown value.
/// A date in a narrow column: the day, and the time under it (`LibraryFormat.tableDateLines`).
struct PaperTableDate: View {
    let date: Date?
    var placeholder: String? = nil
    var body: some View {
        if let date {
            let lines = LibraryFormat.tableDateLines(date)
            VStack(alignment: .leading, spacing: 0) {
                Text(lines.day).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let time = lines.time { Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
            }
            .accessibilityElement(children: .combine)
        } else {
            PaperTableText(text: placeholder)
        }
    }
}

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
    /// A tap on a chip filters the Library by that tag (owner-approved follow-up, 2026-10-07); nil: chips are labels.
    var onTap: ((String) -> Void)? = nil
    var body: some View {
        PaperTableChipFlow(spacing: 4, lineSpacing: 4, maxLines: 2) {
            ForEach(tags, id: \.self) { tag in
                let on = tag == highlighted
                let chip = Text(tag).font(.caption.weight(on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(on ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill), in: Capsule())
                if let onTap {
                    Button { onTap(tag) } label: { chip }.buttonStyle(.plain)
                        .accessibilityIdentifier("library.tagChip.\(tag)")
                        #if targetEnvironment(macCatalyst)
                        .help(on ? "Show all papers" : "Show papers tagged \(tag)")
                        #endif
                } else { chip }
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
