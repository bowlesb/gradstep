import SwiftUI
import ScienceReaderCore

// All chats as a table (owner request 2026-10-07: "a nice table, better more dense rows, not overdoing it … sort them
// based on last used"). It follows the Tables pattern of `PaperTable` (DESIGN.md): a pinned header of column titles
// (tap to sort, again to reverse), one compact aligned row per conversation, and as many columns beside the
// conversation as fit — never a horizontal scroll. Unsent drafts stay above the table. At accessibility text sizes
// rows replace the table. Everything shown is computed on this device from the decrypted history.

/// One column beside the conversation.
struct ChatTableColumn: Identifiable, Equatable {
    let field: ChatHistoryField
    /// 0 is the most important; columns appear in priority order while they fit.
    let priority: Int
    /// Width at the default text size; it grows with Dynamic Type.
    let width: CGFloat
    var alignment: Alignment = .leading
    var id: ChatHistoryField { field }
}

/// Which columns fit. Pure, so it is tested with injected widths.
enum ChatTableLayout {
    static let spacing: CGFloat = 12
    /// The conversation column never gets narrower than this (scaled with text size)…
    static let titleMinimum: CGFloat = 170
    /// …nor, on wide screens, than this share of the row.
    static let titleShare: CGFloat = 0.3

    /// In row order. Last used is rightmost on every size, so the default order reads the same everywhere.
    static let columns: [ChatTableColumn] = [
        ChatTableColumn(field: .paper, priority: 1, width: 200),
        ChatTableColumn(field: .messages, priority: 2, width: 70, alignment: .trailing),
        ChatTableColumn(field: .started, priority: 3, width: 88),
        ChatTableColumn(field: .lastUsed, priority: 0, width: 88),
    ]

    static func titleWidth(in width: CGFloat, scale: CGFloat) -> CGFloat { max(titleMinimum * scale, width * titleShare) }

    /// The columns shown in a row `width` wide (inside the margins), in row order. Taken by priority until the next
    /// one doesn't fit, so a wider screen only ever adds columns.
    static func visible(width: CGFloat, scale: CGFloat = 1) -> [ChatTableColumn] {
        var used = titleWidth(in: width, scale: scale)
        var shown = Set<ChatHistoryField>()
        for column in columns.sorted(by: { $0.priority < $1.priority }) {
            let next = used + spacing + column.width * scale
            guard next <= width else { break }
            used = next
            shown.insert(column.field)
        }
        return columns.filter { shown.contains($0.field) }
    }
}

struct ChatHistoryView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @State private var search = ""
    @State private var filter: ChatHistoryFilter = .all
    @State private var sort = ChatHistorySort.default
    @State private var deleting: ChatHistoryRow?
    /// The list's width; rows sit inside the 16 pt margins.
    @State private var width: CGFloat = 0

    var body: some View {
        let summaries = model.conversationSummaries
        let titles = Dictionary(model.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let rows = ChatHistoryQuery.rows(summaries, paperTitles: titles, filter: filter, search: search, sort: sort)
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
            .navigationTitle("All chats").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .modifier(ChatSearch(text: $search, enabled: !summaries.isEmpty))
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
        .modifier(ChatHistorySizing())
    }

    // MARK: List

    private var tableShown: Bool { !dynamicTypeSize.isAccessibilitySize }
    private var rowWidth: CGFloat { max(0, width - 2 * DesignMetrics.margin) }

    private func list(rows: [ChatHistoryRow], drafts: [ChatWorkspace.UnsentDraft], titles: [UUID: String], total: Int) -> some View {
        let visible = tableShown ? ChatTableLayout.visible(width: rowWidth, scale: scale) : []
        return List {
            // An empty first section takes the plain list's top header padding, so the content starts under the chips.
            Section { Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).accessibilityHidden(true) }
            if !drafts.isEmpty {
                Section {
                    ForEach(drafts) { draft in
                        draftRow(draft, titles: titles, visible: visible)
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
                        conversationRow(row, visible: visible)
                            .listRowInsets(Self.rowInsets)
                            .contextMenu { actions(row) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if model.canDeleteConversations {
                                    // Not a destructive role: the row stays until the deletion is confirmed.
                                    Button { deleting = row } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                                }
                            }
                    }
                } header: {
                    if tableShown { header(visible) } else { sectionTitle(drafts.isEmpty ? nil : "Saved conversations") }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        // On the List only: applied after the inset it would replace the chips' and count's identifiers.
        .accessibilityIdentifier("chat.history.table")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .top, spacing: 0) { if total > 0 { filterBar(shown: rows.count, total: total) } }
        .overlay { if total > 0 && rows.isEmpty && drafts.isEmpty { noMatches } }
    }

    private static let rowInsets = EdgeInsets(top: 7, leading: DesignMetrics.margin, bottom: 7, trailing: DesignMetrics.margin)

    /// The quick filter and how many chats it shows.
    /// Chips never truncate: with large text the count goes first, then the chips scroll sideways.
    private func filterBar(shown: Int, total: Int) -> some View {
        let count = Text(ChatHistoryFormat.count(shown: shown, total: total))
            .font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
            .accessibilityIdentifier("chat.history.count")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips; Spacer(minLength: 8); count }
            HStack(spacing: 8) { chips; Spacer(minLength: 0) }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { chips } }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, DesignMetrics.margin).padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground))
    }

    private var chips: some View {
        ForEach(ChatHistoryFilter.allCases) { option in
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
            ContentUnavailableView(filter == .general ? "No general chats" : "No paper chats", systemImage: "bubble.left.and.bubble.right")
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

    private func header(_ visible: [ChatTableColumn]) -> some View {
        HStack(alignment: .center, spacing: ChatTableLayout.spacing) {
            HStack(spacing: 6) {
                headerCell(.conversation)
                hiddenSortIndicator(visible)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(visible) { column in
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
                Text(field.title).lineLimit(1)
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

    private func conversationRow(_ row: ChatHistoryRow, visible: [ChatTableColumn]) -> some View {
        let paperShown = visible.contains { $0.field == .paper }
        return Button {
            model.openConversation(row.id); dismiss()
        } label: {
            Group {
                if tableShown {
                    HStack(alignment: .firstTextBaseline, spacing: ChatTableLayout.spacing) {
                        ChatTitleCell(title: row.title, subtitle: paperShown ? answerLine(row) : row.contextTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(visible) { column in
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
        .accessibilityIdentifier("chat.history.\(row.id.wire)")
        .accessibilityActions {
            if let paper = paper(for: row) { Button("Open paper") { model.select(paper); dismiss() } }
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
        case .conversation: EmptyView()
        }
    }

    private func spokenValue(_ row: ChatHistoryRow) -> String {
        [row.isPaperChat ? "Paper chat, \(row.contextTitle)" : "General chat",
         ChatHistoryFormat.spokenLastUsed(row.summary.lastUsedAt),
         ChatHistoryFormat.messages(row.summary.messageCount)].compactMap { $0 }.joined(separator: ", ")
    }

    private func paper(for row: ChatHistoryRow) -> Paper? {
        row.summary.documentID.flatMap { id in model.papers.first { $0.id == id } }
    }

    @ViewBuilder private func actions(_ row: ChatHistoryRow) -> some View {
        if let paper = paper(for: row) {
            Button("Open paper", systemImage: "doc.text") { model.select(paper); dismiss() }
        }
        if model.canDeleteConversations {
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
        default: break
        }
        let context = draftContext(draft, titles: titles)
        return search.split(whereSeparator: \.isWhitespace).allSatisfy {
            draft.text.localizedStandardContains($0) || context.localizedStandardContains($0)
        }
    }

    private func draftRow(_ draft: ChatWorkspace.UnsentDraft, titles: [UUID: String], visible: [ChatTableColumn]) -> some View {
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

/// Search appears only when there is something to search.
private struct ChatSearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
        } else { content }
    }
}

/// A table wants the room: the page-sized sheet on iPad (still a sheet, dismissed the same way); full height on iPhone.
private struct ChatHistorySizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.presentationSizing(.page) } else { content }
    }
}
