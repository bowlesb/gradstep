import SwiftUI
import ScienceReaderCore

// All chats as a table (owner request 2026-10-07: "a nice table, better more dense rows, not overdoing it … sort them
// based on last used"). It follows the Tables pattern of `PaperTable` (DESIGN.md): a pinned header of column titles
// (tap to sort, again to reverse), one compact aligned row per conversation, and the reader's columns (build 16 #3:
// "choose which columns to show and also allow horizontal scrolling"): when they don't fit, they scroll sideways
// between the pinned conversation and Last used. Unsent drafts stay above the table. At accessibility text sizes rows
// replace the table. Everything shown is computed on this device from the decrypted history.

/// One column beside the conversation.
struct ChatTableColumn: Identifiable, Equatable {
    let field: ChatHistoryField
    /// 0 is the most important; columns appear in priority order while they fit.
    let priority: Int
    /// Width at the default text size; it grows with Dynamic Type.
    let width: CGFloat
    var alignment: Alignment = .leading
    /// Stays at the trailing edge while the other columns scroll (Last used).
    var pinned = false
    var id: ChatHistoryField { field }
}

/// Which columns fit. Pure, so it is tested with injected widths.
enum ChatTableLayout {
    static let spacing: CGFloat = 12
    /// The conversation column never gets narrower than this (scaled with text size)…
    static let titleMinimum: CGFloat = 170
    /// …nor, on wide screens, than this share of the row.
    static let titleShare: CGFloat = 0.3

    /// In row order. Last used is rightmost on every size (and stays there while the others scroll), so the default
    /// order reads the same everywhere.
    static let columns: [ChatTableColumn] = [
        ChatTableColumn(field: .paper, priority: 1, width: 200),
        ChatTableColumn(field: .kind, priority: 5, width: 84),
        ChatTableColumn(field: .topics, priority: 6, width: 150),
        ChatTableColumn(field: .messages, priority: 2, width: 70, alignment: .trailing),
        ChatTableColumn(field: .started, priority: 3, width: 88),
        ChatTableColumn(field: .answerLength, priority: 4, width: 104, alignment: .trailing),
        ChatTableColumn(field: .lastUsed, priority: 0, width: 88, pinned: true),
    ]
    /// The columns the reader chooses (Columns in All chats' "…"); Last used always shows.
    static let choosable: [ChatHistoryField] = [.paper, .kind, .topics, .messages, .started, .answerLength]
    /// Paper, Messages and Started, as before (iPhone portrait scrolls to them; landscape and iPad show them).
    static let compactDefault: Set<ChatHistoryField> = [.paper, .messages, .started]
    static let regularDefault: Set<ChatHistoryField> = [.paper, .messages, .started]

    static func titleWidth(in width: CGFloat, scale: CGFloat) -> CGFloat { max(titleMinimum * scale, width * titleShare) }

    /// The chosen columns (and Last used), in row order.
    static func columns(_ chosen: Set<ChatHistoryField>) -> [ChatTableColumn] {
        columns.filter { $0.field == .lastUsed || chosen.contains($0.field) }
    }

    /// The columns that fit in a row `width` wide (inside the margins), in row order. Taken by priority until the next
    /// one doesn't fit, so a wider screen only ever adds columns.
    static func visible(_ chosen: Set<ChatHistoryField> = compactDefault, width: CGFloat, scale: CGFloat = 1) -> [ChatTableColumn] {
        let shown = TableArrangement.fit(columns(chosen).map(item), rowWidth: width, titleMinimum: titleMinimum, titleShare: titleShare,
                                         spacing: spacing, scale: scale)
        return columns(chosen).filter { shown.contains($0.field.rawValue) }
    }

    /// Every chosen column: those that don't fit scroll sideways between the conversation and Last used.
    static func arrangement(_ chosen: Set<ChatHistoryField>, width: CGFloat, scale: CGFloat = 1) -> TableArrangement {
        TableArrangement.make(columns(chosen).map(item), rowWidth: width, titleMinimum: titleMinimum, titleShare: titleShare,
                              spacing: spacing, scale: scale, scrolling: true)
    }

    private static func item(_ column: ChatTableColumn) -> TableArrangement.Item {
        TableArrangement.Item(id: column.field.rawValue, priority: column.priority, width: column.width, pinned: column.pinned)
    }
}

struct ChatHistoryView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @State private var search = ""
    @State private var localFilter: ChatHistoryFilter
    /// Opened from a paper (its paper or chat screen): "This paper" is offered after All. Kept for the sheet's life, so
    /// the table doesn't change while it closes.
    @State private var localPaperID: UUID?
    /// The sheet's order (a fresh one each time it opens); the Chat place's list keeps its own on the model.
    @State private var localSort = ChatHistorySort.default
    @State private var deleting: ChatHistoryRow?
    @State private var renaming: UUID?
    /// The list's width; rows sit inside the 16 pt margins.
    @State private var width: CGFloat = 0
    @State private var scroll = TableScrollState()
    @State private var showColumns = false
    /// iPad Wide's Chats view: the list in the left slot beside the open chat (no Close; its row is the slot's share of
    /// the one top row).
    private let embedded: Bool

    /// The quick filter and the paper whose "This paper" is offered: the sheet's own; the Chat place's list (iPad Wide)
    /// takes them from the route that showed it (ReaderModel.openAllChats).
    private var filter: ChatHistoryFilter {
        get { embedded ? model.chatsListFilter : localFilter }
        nonmutating set { if embedded { model.chatsListFilter = newValue } else { localFilter = newValue } }
    }
    private var paperID: UUID? { embedded ? model.chatsListPaperID : localPaperID }

    /// The order shown: the Chat place's list (iPad Wide) keeps it while the reader goes elsewhere and back.
    private var sort: ChatHistorySort {
        get { embedded ? model.chatsListSort : localSort }
        nonmutating set { if embedded { model.chatsListSort = newValue } else { localSort = newValue } }
    }

    init(model: ReaderModel, paperID: UUID? = nil, startsOnPaper: Bool = false, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
        _localPaperID = State(initialValue: paperID)
        // Owner, build 57: "put All to the left and make that the default"; a paper's own "Chats about this paper" opens on those.
        _localFilter = State(initialValue: startsOnPaper && paperID != nil ? .thisPaper : .all)
    }

    var body: some View {
        let summaries = model.conversationSummaries
        let titles = Dictionary(model.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let topics = Dictionary(model.papers.map { ($0.id, $0.tags.isEmpty ? ArxivTopics.names(for: $0.keywords) : $0.tags) },
                                uniquingKeysWith: { first, _ in first })
        let rows = ChatHistoryQuery.rows(summaries, paperTitles: titles, filter: filter, paperID: paperID, search: search, sort: sort,
                                         paperTopics: topics)
        let drafts = model.unsentDrafts.filter { includes($0, titles: titles) }
        NavigationStack {
            Group {
                if summaries.isEmpty && model.unsentDrafts.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: { Text("Questions you ask about papers, and general chats, are kept here.") }
                } else {
                    list(rows: rows, drafts: drafts, titles: titles, total: summaries.count)
                }
            }
            .navigationTitle("All chats").toolbar(.hidden, for: .navigationBar)
            // Owner, build 57: "the search bar at the top with the three lines at the right of the search bar… done can be
            // an option remove it. All chats message can also go. simplify".
            .safeAreaInset(edge: .top, spacing: 0) {
                if embedded { slotRow(searchable: !summaries.isEmpty) } else { topRow(searchable: !summaries.isEmpty) }
            }
            .renameConversationAlert(model: model, conversation: $renaming)
            .slotSheet(isPresented: $showColumns) { columnsSheet }
            .alert("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { row in
                Button("Delete", role: .destructive) { Task { await model.deleteConversation(row.id) } }
                    .accessibilityIdentifier("chat.history.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text("“\(row.title)” will be removed from your chats on all your devices.")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Top

    /// The Chats view's left slot: the search field and the list's options on the one top row.
    private func slotRow(searchable: Bool) -> some View {
        WideBar {
            if searchable { WideSearchField { searchField } } else { Text("All chats").font(.headline).accessibilityAddTraits(.isHeader) }
        } center: {
            EmptyView()
        } trailing: {
            // The list's own options beside the chat (owner, 2026-10-24: "Why are those options not on the list on the
            // left?"), as the Library list's ⋯ has them: Sort by, with the order shown under it; Columns with a table.
            if searchable {
                Menu {
                    Menu {
                        Picker("Sort by", selection: Binding(get: { sort.field }, set: { field in
                            sort = ChatHistorySort(field: field, ascending: field.ascendingFirst)
                        })) {
                            ForEach(sortFields, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline)
                    } label: {
                        Label { Text("Sort by"); Text(sort.field.title) } icon: { Image(systemName: "arrow.up.arrow.down") }
                    }
                    .accessibilityIdentifier("chat.history.sort")
                    if tableShown {
                        MenuRow("Columns", systemImage: "tablecells") { showColumns = true }.accessibilityIdentifier("chat.history.columns")
                    }
                } label: { HeaderButtonLabel(systemImage: "ellipsis") }
                .buttonStyle(.plain).accessibilityLabel("All chats options").accessibilityIdentifier("chat.history.options")
            }
        }
    }

    /// What the list can be sorted by: with rows (the Chat place's narrow slot, accessibility sizes) what a row shows;
    /// the table sorts by any of its columns.
    private var sortFields: [ChatHistoryField] {
        tableShown ? ChatHistoryField.allCases : [.lastUsed, .started, .messages, .conversation, .paper]
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).accessibilityIdentifier("chat.history.search")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
    }

    /// The search field and, at its right, ≡ with the options: Sort by, Columns, Close.
    private func topRow(searchable: Bool) -> some View {
        HStack(spacing: 10) {
            if searchable {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).accessibilityIdentifier("chat.history.search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            } else {
                Spacer(minLength: 0)
            }
            Menu {
                if tableShown && searchable {
                    Menu {
                        Picker("Sort by", selection: Binding(get: { sort.field }, set: { field in
                            sort = ChatHistorySort(field: field, ascending: field.ascendingFirst)
                        })) {
                            ForEach(ChatHistoryField.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline)
                    } label: { Label("Sort by", systemImage: "arrow.up.arrow.down") }
                    MenuRow("Columns", systemImage: "tablecells") { showColumns = true }.accessibilityIdentifier("chat.history.columns")
                }
                Section { MenuRow("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("chat.history.close") }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).modifier(GlassCircle()).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityLabel("All chats options").accessibilityIdentifier("chat.history.options")
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 12).padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
        // Esc closes, as Done did.
        .background { Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true) }
    }

    // MARK: List

    /// The Chats view's narrow left slot shows the list's rows, as at accessibility sizes.
    private var tableShown: Bool { !dynamicTypeSize.isAccessibilitySize && !embedded }
    private var rowWidth: CGFloat { max(0, width - 2 * DesignMetrics.margin) }

    private var chosenColumns: Set<ChatHistoryField> { model.chatColumns[.current] }

    /// All chats › "…" › Columns.
    private var columnsSheet: some View {
        let widthClass = LibraryColumnSettings.WidthClass.current
        let chosen = model.chatColumns[widthClass]
        let fitting = Set(ChatTableLayout.visible(chosen, width: rowWidth, scale: scale).map(\.field))
        return ColumnChooserSheet(
            identifier: "chat.history.columns", titleRow: ("Conversation", "The first question, and under it the paper or the newest answer"),
            options: ChatTableLayout.choosable.map { .init(id: $0.rawValue, title: $0.title, explanation: $0.explanation) },
            fixed: [(ChatHistoryField.lastUsed.title, ChatHistoryField.lastUsed.explanation)],
            chosen: Binding(get: { Set(model.chatColumns[widthClass].map(\.rawValue)) },
                            set: { model.chatColumns[widthClass] = Set($0.compactMap(ChatHistoryField.init(rawValue:))) }),
            defaults: Set(model.chatColumns.defaults(widthClass).map(\.rawValue)),
            scrolling: Set(chosen.subtracting(fitting).map(\.rawValue)),
            footer: TableColumnWording.footer(widthClass))
    }

    private func columns(_ ids: [String]) -> [ChatTableColumn] {
        ids.compactMap { id in ChatTableLayout.columns.first { $0.field.rawValue == id } }
    }

    private func list(rows: [ChatHistoryRow], drafts: [ChatWorkspace.UnsentDraft], titles: [UUID: String], total: Int) -> some View {
        let arrangement = tableShown ? ChatTableLayout.arrangement(chosenColumns, width: rowWidth, scale: scale) : TableArrangement(columns: [])
        return HorizontalTableScroll(state: scroll, extent: arrangement.extent, snapOffsets: arrangement.snapOffsets) {
            table(rows: rows, drafts: drafts, titles: titles, total: total, arrangement: arrangement)
        }
        // On the List only: applied after the inset it would replace the chips' and count's identifiers.
        .safeAreaInset(edge: .top, spacing: 0) { if total > 0 { filterBar(shown: rows.count, total: total) } }
        .overlay { if total > 0 && rows.isEmpty && drafts.isEmpty { noMatches } }
    }

    private func table(rows: [ChatHistoryRow], drafts: [ChatWorkspace.UnsentDraft], titles: [UUID: String], total: Int,
                       arrangement: TableArrangement) -> some View {
        let visible = columns(arrangement.columns) + columns(arrangement.pinned)
        return ScrollViewReader { proxy in List {
            // An empty first section takes the plain list's top header padding, so the content starts under the chips.
            Section { Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).accessibilityHidden(true) }
            if !drafts.isEmpty {
                Section {
                    ForEach(drafts) { draft in
                        draftRow(draft, titles: titles, visible: visible, arrangement: arrangement)
                            .listRowInsets(Self.rowInsets)
                            .contextMenu {
                                Button("Discard draft", systemImage: "trash", role: .destructive) { model.discardUnsentDraft(draft.id) }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Discard", role: .destructive) { model.discardUnsentDraft(draft.id) }
                            }
                    }
                } header: {
                    sectionTitle("Unsent drafts")
                } footer: {
                    Text(model.draftsArePersistent ? "Drafts stay on this device." : "Kept for this session.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, DesignMetrics.margin).padding(.vertical, 8)
                        .listRowInsets(EdgeInsets())
                }
            }
            if total > 0 {
                Section {
                    ForEach(rows) { row in
                        conversationRow(row, visible: visible, arrangement: arrangement)
                            .listRowInsets(Self.rowInsets)
                            // The conversation beside the list, as the Feed's picked row (accent at 12%).
                            .listRowBackground(isOpen(row) ? Color.accentColor.opacity(0.12) : nil)
                            .contextMenu { actions(row) }
                            // While the columns scroll, a sideways swipe scrolls them; Delete stays in the row's menu.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if model.canDeleteConversations && !arrangement.scrolls {
                                    // Not a destructive role: the row stays until the deletion is confirmed.
                                    Button { deleting = row } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                                }
                            }
                    }
                } header: {
                    if tableShown { header(arrangement) } else { sectionTitle(drafts.isEmpty ? nil : "Saved conversations") }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityIdentifier("chat.history.table")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The Chat place opens on the conversation the reader was in (owner, 2026-10-24): its row is brought into view.
        .task(id: embedded ? model.activeConversation : nil) {
            guard embedded, let open = model.activeConversation, rows.contains(where: { $0.id == open }) else { return }
            await Task.yield()
            proxy.scrollTo(open)
        }
        } // ScrollViewReader
    }

    /// The Chat place's list (iPad Wide): the row of the conversation shown beside it.
    private func isOpen(_ row: ChatHistoryRow) -> Bool { embedded && model.activeConversation == row.id }

    private static let rowInsets = EdgeInsets(top: 7, leading: DesignMetrics.margin, bottom: 7, trailing: DesignMetrics.margin)

    /// The quick filter and how many chats it shows.
    /// Chips never truncate: with large text the count goes first, then the chips scroll sideways.
    private func filterBar(shown: Int, total: Int) -> some View {
        let count = Text(ChatHistoryFormat.count(shown: shown, total: total))
            .font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
            .accessibilityIdentifier("chat.history.count")
        return Group {
            if paperID == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips; Spacer(minLength: 8); count }
                    HStack(spacing: 8) { chips; Spacer(minLength: 0) }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { chips } }
                }
            } else {
                // A fourth chip (opened from a paper): the count, which says how many chats are this paper's, moves
                // under the chips rather than being left out.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips; Spacer(minLength: 8); count }
                    VStack(alignment: .leading, spacing: 0) { HStack(spacing: 8) { chips; Spacer(minLength: 0) }; count }
                    VStack(alignment: .leading, spacing: 0) { ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { chips } }; count }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, DesignMetrics.margin).padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground))
    }

    /// All first (the default), then "This paper" when opened from a paper, Paper chats and General.
    private var chips: some View {
        let options = [ChatHistoryFilter.all] + (paperID == nil ? [] : [.thisPaper]) + [.paper, .general]
        return ForEach(options) { option in
            ChipButton(title: option.title, selected: filter == option) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { filter = option }
            }
            .fixedSize()
            .accessibilityIdentifier("chat.history.filter.\(option.rawValue)")
        }
    }

    @ViewBuilder private var noMatches: some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView(filter == .general ? "No general chats" : filter == .thisPaper ? "No chats about this paper" : "No paper chats",
                                   systemImage: "bubble.left.and.bubble.right")
        }
    }

    @ViewBuilder private func sectionTitle(_ title: String?) -> some View {
        if let title {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignMetrics.margin).padding(.top, 10).padding(.bottom, 4)
                .listRowInsets(EdgeInsets())
                .background(Color(uiColor: .systemBackground))
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Header

    private func header(_ arrangement: TableArrangement) -> some View {
        let visible = columns(arrangement.columns), pinned = columns(arrangement.pinned)
        return HStack(alignment: .center, spacing: ChatTableLayout.spacing) {
            HStack(spacing: 6) {
                headerCell(.conversation)
                hiddenSortIndicator(ChatTableLayout.visible(chosenColumns, width: rowWidth, scale: scale))
            }
            .frame(maxWidth: arrangement.titleWidth ?? .infinity, alignment: .leading)
            .frame(width: arrangement.titleWidth, alignment: .leading)
            if arrangement.usesColumnRegion {
                TableScrollRegion(state: scroll, width: arrangement.regionWidth, extent: arrangement.extent) {
                    HStack(alignment: .center, spacing: ChatTableLayout.spacing) {
                        ForEach(visible) { column in
                            headerCell(column.field).frame(width: arrangement.columnWidth(column.width * scale), alignment: column.alignment)
                        }
                    }
                }
            }
            ForEach(arrangement.usesColumnRegion ? pinned : visible) { column in
                headerCell(column.field).frame(width: column.width * scale, alignment: column.alignment)
            }
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets())
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
    }

    private func headerCell(_ field: ChatHistoryField) -> some View {
        let current = sort.field == field
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { sort = sort.tapping(field) }
        } label: {
            HStack(spacing: 3) {
                Text(field.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if current { chevron }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(current ? Color.accentColor : Color(uiColor: .secondaryLabel))
            .frame(minHeight: 36).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(field.title)
        .accessibilityValue(current ? (sort.ascending ? "Sorted ascending" : "Sorted descending") : "")
        .accessibilityHint(current ? "Reverses the order" : "Sorts by this column")
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chat.history.header.\(field.rawValue)")
    }

    private var chevron: some View {
        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
    }

    /// The order still shows when its column doesn't fit (a phone sorted by Started in landscape, then rotated):
    /// "· Started ⌄" beside Conversation; tapping it reverses the order.
    @ViewBuilder private func hiddenSortIndicator(_ visible: [ChatTableColumn]) -> some View {
        if sort.field != .conversation, !visible.contains(where: { $0.field == sort.field }) {
            Text("·").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { sort.ascending.toggle() }
            } label: {
                HStack(spacing: 3) { Text(sort.field.title).lineLimit(1); chevron }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sorted by \(sort.field.title)")
            .accessibilityValue(sort.ascending ? "Ascending" : "Descending")
            .accessibilityHint("Reverses the order")
            .accessibilityIdentifier("chat.history.sortIndicator")
        }
    }

    // MARK: Rows

    private func conversationRow(_ row: ChatHistoryRow, visible: [ChatTableColumn], arrangement: TableArrangement) -> some View {
        // With the Paper column chosen the paper is only in its column (owner, build 57: "The paper should only be in its
        // column not duplicated on left column"), even while it is scrolled aside.
        let paperShown = chosenColumns.contains(.paper)
        return Button {
            model.openConversation(row.id); dismiss()
        } label: {
            Group {
                if tableShown {
                    HStack(alignment: .firstTextBaseline, spacing: ChatTableLayout.spacing) {
                        // With the Paper column shown, a chat from a passage shows that passage; else the newest answer.
                        ChatTitleCell(title: row.title, subtitle: paperShown ? (row.passageLine ?? answerLine(row)) : row.contextTitle)
                            .frame(maxWidth: arrangement.titleWidth ?? .infinity, alignment: .leading)
                            .frame(width: arrangement.titleWidth, alignment: .leading)
                        if arrangement.usesColumnRegion {
                            TableScrollRegion(state: scroll, width: arrangement.regionWidth, extent: arrangement.extent) {
                                HStack(alignment: .firstTextBaseline, spacing: ChatTableLayout.spacing) {
                                    ForEach(columns(arrangement.columns)) { column in
                                        cell(row, column.field).frame(width: arrangement.columnWidth(column.width * scale), alignment: column.alignment)
                                    }
                                }
                            }
                        }
                        ForEach(arrangement.usesColumnRegion ? columns(arrangement.pinned) : visible) { column in
                            cell(row, column.field).frame(width: column.width * scale, alignment: column.alignment)
                        }
                    }
                } else {
                    ChatHistoryLargeRow(title: row.title, context: row.contextTitle,
                                        detail: [ChatHistoryFormat.lastUsed(row.summary.lastUsedAt),
                                                 ChatHistoryFormat.messages(row.summary.messageCount)].joined(separator: " · "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The title is the label (tests and Voice Control find the conversation by it); the columns are its value.
        .accessibilityLabel(row.title)
        .accessibilityValue(spokenValue(row))
        .accessibilityHint("Opens the conversation")
        .accessibilityAddTraits(isOpen(row) ? .isSelected : [])
        .accessibilityIdentifier("chat.history.\(row.id.wire)")
        .accessibilityActions {
            if let paper = paper(for: row) { Button("Open paper") { model.select(paper); dismiss() } }
            if model.canGoToPassage(row.id) { Button("Go to passage") { dismiss(); model.goToPassage(row.id) } }
            if model.canDeleteConversations { Button("Rename") { renaming = row.id } }
            if model.canDeleteConversations { Button("Delete") { deleting = row } }
        }
    }

    /// The newest answer as one line; the message count when nothing was answered yet.
    private func answerLine(_ row: ChatHistoryRow) -> String {
        let preview = row.summary.latestAnswer.map { ChatPreview.plain($0) } ?? ""
        return preview.isEmpty ? ChatHistoryFormat.messages(row.summary.messageCount) : preview
    }

    @ViewBuilder private func cell(_ row: ChatHistoryRow, _ field: ChatHistoryField) -> some View {
        switch field {
        case .paper:
            Text(row.contextTitle).font(.subheadline).foregroundStyle(row.paperTitle == nil ? .tertiary : .secondary)
                .lineLimit(2).truncationMode(.tail)
        case .lastUsed: ChatTableText(text: ChatHistoryFormat.lastUsed(row.summary.lastUsedAt))
        case .started: ChatTableText(text: ChatHistoryFormat.started(row.summary.startedAt))
        case .messages: ChatTableText(text: String(row.summary.messageCount))
        case .kind: ChatTableText(text: row.isPaperChat ? "Paper" : "General")
        case .answerLength: ChatTableText(text: ChatHistoryFormat.words(row.summary.latestAnswerWords))
        case .topics: PaperTableChips(tags: row.topics)
        case .conversation: EmptyView()
        }
    }

    private func spokenValue(_ row: ChatHistoryRow) -> String {
        [row.isPaperChat ? "Paper chat, \(row.contextTitle)" : "General chat",
         ChatHistoryFormat.spokenLastUsed(row.summary.lastUsedAt),
         ChatHistoryFormat.messages(row.summary.messageCount),
         chosenColumns.contains(.answerLength) && row.summary.latestAnswerWords > 0
            ? "newest answer \(ChatHistoryFormat.words(row.summary.latestAnswerWords))" : nil,
         chosenColumns.contains(.topics) && !row.topics.isEmpty ? "Topics: " + row.topics.joined(separator: ", ") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func paper(for row: ChatHistoryRow) -> Paper? {
        row.summary.documentID.flatMap { id in model.papers.first { $0.id == id } }
    }

    @ViewBuilder private func actions(_ row: ChatHistoryRow) -> some View {
        if let paper = paper(for: row) {
            Button("Open paper", systemImage: "doc.text") { model.select(paper); dismiss() }
        }
        if model.canGoToPassage(row.id) {
            Button("Go to passage", systemImage: "text.quote") { dismiss(); model.goToPassage(row.id) }
        }
        if model.canDeleteConversations {
            Button("Rename…", systemImage: "pencil") { renaming = row.id }
            Button("Delete conversation", systemImage: "trash", role: .destructive) { deleting = row }
        }
    }

    // MARK: Drafts

    private func draftContext(_ draft: ChatWorkspace.UnsentDraft, titles: [UUID: String]) -> String {
        if draft.context == "general" { return "General chat" }
        let id = UUID(uuidString: String(draft.context.dropFirst("paper/".count)))
        return id.flatMap { titles[$0] } ?? "Paper chat"
    }

    private func includes(_ draft: ChatWorkspace.UnsentDraft, titles: [UUID: String]) -> Bool {
        switch filter {
        case .paper where draft.context == "general", .general where draft.context != "general": return false
        case .thisPaper where paperID == nil || UUID(uuidString: String(draft.context.dropFirst("paper/".count))) != paperID: return false
        default: break
        }
        let context = draftContext(draft, titles: titles)
        return search.split(whereSeparator: \.isWhitespace).allSatisfy {
            draft.text.localizedStandardContains($0) || context.localizedStandardContains($0)
        }
    }

    private func draftRow(_ draft: ChatWorkspace.UnsentDraft, titles: [UUID: String], visible: [ChatTableColumn],
                          arrangement: TableArrangement) -> some View {
        let text = draft.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft.text
        let context = draftContext(draft, titles: titles)
        let status = draft.failed ? "Not saved" : "Draft"
        return Button {
            model.openUnsentDraft(draft.id); dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ChatTableLayout.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: draft.failed ? "exclamationmark.circle.fill" : "pencil")
                        .font(.footnote.weight(.semibold)).foregroundStyle(draft.failed ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    ChatTitleCell(title: text, subtitle: "\(status) · \(context)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if tableShown, let column = visible.first(where: { $0.field == .lastUsed }) {
                    ChatTableText(text: ChatHistoryFormat.lastUsed(draft.editedAt)).frame(width: column.width * scale, alignment: column.alignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status): \(draft.text)")
        .accessibilityValue(context)
        .accessibilityHint("Opens the draft")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.draft.\(draft.id.wire)")
    }
}

/// The conversation cell: the question (one line) and under it, muted, the paper or the newest answer.
struct ChatTitleCell: View {
    let title: String
    let subtitle: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        // One line each in the table; drafts at accessibility sizes wrap instead.
        let lines = dynamicTypeSize.isAccessibilitySize ? 4 : 1
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(lines).truncationMode(.tail)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(lines).truncationMode(.tail)
        }
    }
}

/// A plain value: secondary, one line, digits aligned.
struct ChatTableText: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
    }
}

/// The row at accessibility text sizes: the question, what it is about, then when and how long.
struct ChatHistoryLargeRow: View {
    let title: String
    let context: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(4)
            Text(context).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

