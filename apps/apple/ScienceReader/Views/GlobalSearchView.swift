import SwiftUI
import ScienceReaderCore

/// The search screen (docs/architecture/GLOBAL_SEARCH.md "The screen"; proposal B.5): one field over everything on this
/// device. Empty, it shows recent searches and what was opened recently; as you type, results grouped (Papers, Chats,
/// Explanations, Snippets, Diagrams, Feed, Tags, Settings) with each group's best three and "See all"; chips choose a
/// group. From a paper, an "In this paper" token scopes it. The last row is always "Search ML papers for “…”", the only
/// network action. Wide (iPad sideways, Mac): the results on the left, the picked result on the right; the list stays.
struct GlobalSearchView: View {
    @Bindable var model: ReaderModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.tabBarReserve) private var tabBarReserve
    @Environment(\.placesLeadingReserve) private var placesReserve
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var announced: String?

    private var search: GlobalSearchModel { model.globalSearch }

    /// The ⓘ after the field.
    static let info = "Searches your papers (titles, authors, tags, abstracts and the text of papers saved here), your chats and "
        + "their answers, kept equation, figure and paper explanations, snippets (with text in their pictures), diagrams, the Feed's "
        + "current page, tags and Settings. It runs on this device and nothing you type is sent; only “Search ML papers” asks "
        + "arXiv. Explanations are kept on the device that made them."

    var body: some View {
        Group {
            if model.compactLayout { results }
            else {
                // Wide: the list beside the picked result (Mail's two slots).
                GeometryReader { geometry in
                    let listWidth = min(440, max(320, (geometry.size.width * 0.36).rounded()))
                    HStack(spacing: 0) {
                        results.frame(width: listWidth)
                        Divider().ignoresSafeArea()
                        picked.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear {
            // The keyboard comes up when the screen opens with nothing typed (owner's answer to the proposal's question 4).
            if search.trimmedQuery.isEmpty { fieldFocused = true }
        }
        .onChange(of: search.focusRequest) { _, _ in fieldFocused = true }
        // The result count is announced once typing pauses (VoiceOver).
        .task(id: search.results.query + "\(search.results.total)") {
            guard !search.results.query.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let words = search.results.isEmpty ? "No results" : "\(search.results.total) \(search.results.total == 1 ? "result" : "results")"
            if announced != words { announced = words; AccessibilityNotification.Announcement(words).post() }
        }
        .accessibilityIdentifier("search.screen")
    }

    // MARK: The list

    private var results: some View {
        VStack(spacing: 0) {
            header
            if !search.trimmedQuery.isEmpty { chips }
            statusLines
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.trimmedQuery.isEmpty { emptyState } else { groups; mlRow }
                }
                .padding(.bottom, tabBarReserve + 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("search.results")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                if let scope = search.scope {
                    // "In this paper", removable.
                    Button { search.removeScope() } label: {
                        HStack(spacing: 4) {
                            Text("In this paper").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("In this paper: \(scope.title)").accessibilityHint("Removes the paper scope")
                    .accessibilityIdentifier("search.scope")
                }
                TextField(search.scope == nil ? "Search everything" : "Search this paper", text: Binding(get: { search.query }, set: { search.query = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($fieldFocused)
                    .onSubmit { openFirst() }
                    .accessibilityIdentifier("search.field")
                if !search.query.isEmpty {
                    Button { search.query = ""; fieldFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search").accessibilityIdentifier("search.clear")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: DesignMetrics.headerControl)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            InfoButton(text: Self.info, identifier: "search.info")
            Button("Cancel") { cancel() }
                .font(.body).padding(.leading, 4)
                .accessibilityIdentifier("search.cancel")
        }
        .padding(.leading, DesignMetrics.margin + (model.compactLayout ? 0 : placesReserve)).padding(.trailing, DesignMetrics.margin)
        .padding(.top, 8).padding(.bottom, 6)
        .onKeyPress(.escape) { cancel(); return .handled }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GlobalSearchChip.allCases) { chip in
                    let selected = search.chip == chip
                    Button { search.chip = chip } label: {
                        Text(chip.title).font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("search.chip.\(chip.rawValue)")
                }
            }
            .padding(.horizontal, DesignMetrics.margin + (model.compactLayout ? 0 : placesReserve)).padding(.vertical, 4)
        }
    }

    /// One quiet line at most: the first build's progress, a corrected word, or partial matches.
    @ViewBuilder private var statusLines: some View {
        if let indexing = search.indexing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Indexing chats and explanations · \(Int((indexing * 100).rounded()))%")
            }
            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 4)
            .accessibilityIdentifier("search.indexing")
        }
        if let correction = search.results.correction, !search.trimmedQuery.isEmpty {
            (Text("No exact matches · showing ") + Text(correction).italic())
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 4)
                .accessibilityIdentifier("search.correction")
        } else if search.results.partial, !search.trimmedQuery.isEmpty {
            Text("Results with some of your words").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, DesignMetrics.margin).padding(.vertical, 4)
                .accessibilityIdentifier("search.partial")
        }
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if !search.recentSearches.isEmpty {
            HStack {
                sectionTitle("Recent")
                Spacer()
                Button("Clear") { search.clearRecentSearches() }.font(.subheadline).accessibilityIdentifier("search.recent.clear")
            }
            .padding(.trailing, DesignMetrics.margin)
            ForEach(Array(search.recentSearches.enumerated()), id: \.offset) { index, words in
                Button { search.query = words } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 24)
                        Text(words).lineLimit(1).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DesignMetrics.margin).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("search.recent.\(index)")
            }
        }
        if !search.recentItems.isEmpty {
            sectionTitle("Recently opened")
            ForEach(search.recentItems) { row in rowButton(row, compact: true) }
        }
    }

    // MARK: Results

    @ViewBuilder private var groups: some View {
        let results = search.results
        if results.isEmpty {
            if !search.searching && results.query == search.query {
                Text("No results for “\(search.trimmedQuery)”").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 16)
                    .accessibilityIdentifier("search.none")
            }
        } else {
            ForEach(results.groups) { group in
                sectionTitle(title(group) + " · \(group.total)")
                    .accessibilityIdentifier("search.group.\(group.group.rawValue)")
                if search.chip != .all, let summary = group.summary {
                    Text(summary).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, DesignMetrics.margin).padding(.bottom, 4)
                }
                ForEach(group.rows) { row in
                    rowButton(row)
                        .onAppear { if search.chip != .all, row.id == group.rows.last?.id { search.showMore() } }
                }
                if search.chip == .all, group.total > group.rows.count, group.group != .passages || search.scope != nil {
                    Button { search.chip = GlobalSearchChip.showing(group.group) } label: {
                        HStack {
                            Text("See all \(group.total)").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, DesignMetrics.margin).frame(minHeight: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("search.seeAll.\(group.group.rawValue)")
                }
            }
        }
    }

    private func title(_ group: GlobalSearchGroup) -> String {
        search.scope != nil && group.group == .chats ? "Chats about this paper" : group.group.title
    }

    /// The last row, always: ML paper search for the words (the existing search, sent only on a tap).
    private var mlRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 8)
            Button { model.searchMLPapersFromGlobalSearch() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe").foregroundStyle(Color.accentColor).frame(width: 24)
                    Text("Search ML papers for “\(search.trimmedQuery)”").foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DesignMetrics.margin).frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Searches arXiv for these words")
            .accessibilityIdentifier("search.ml")
            if Connectivity.shared.isOffline {
                Text(ConnectionText.offline).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, DesignMetrics.margin)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, DesignMetrics.margin).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func rowButton(_ row: GlobalSearchRow, compact: Bool = false) -> some View {
        Button { open(row) } label: {
            GlobalSearchRowView(row: row, compact: compact, selected: search.picked?.id == row.id && !model.compactLayout)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityHint(row.hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("search.row.\(row.id)")
    }

    // MARK: Actions

    private func open(_ row: GlobalSearchRow) {
        fieldFocused = false
        model.openSearchResult(row, wide: !model.compactLayout)
    }

    /// Return: the first result.
    private func openFirst() {
        search.remember()
        if let first = search.results.groups.first?.rows.first { open(first) }
    }

    private func cancel() {
        fieldFocused = false
        model.closeGlobalSearch()
    }

    // MARK: Wide: the picked result

    @ViewBuilder private var picked: some View {
        switch search.picked?.target {
        case .paper, .passage, .explanation:
            PaperView(model: model)
        case .conversation, .message:
            ChatView(model: model)
        case .collection(let id), .snippet(let id, _):
            NoteDetailView(model: model, noteID: id, showsBack: false).id(id)
        default:
            ContentUnavailableView {
                Label("Search everything", systemImage: "magnifyingglass")
            } description: {
                Text(search.trimmedQuery.isEmpty ? "Papers, chats, explanations, snippets and Settings." : "Pick a result to see it here.")
            }
            .accessibilityIdentifier("search.pickPlaceholder")
        }
    }
}

/// One result: the kind's symbol, the title (one line, matched words marked), a quiet line of where it lives, and the
/// match line (two lines reserved, so rows never change height while typing).
struct GlobalSearchRowView: View {
    let row: GlobalSearchRow
    var compact = false
    var selected = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbol).font(.system(size: 16)).foregroundStyle(Color.accentColor).frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchMatchLine.marked(row.title, row.titleHighlights)).font(.body).foregroundStyle(.primary).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !compact {
                    Text(matchLine).font(.footnote).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    if row.more > 0 {
                        Text("+\(row.more) more in this \(row.group == .snippets ? "collection" : "chat")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    /// The strength (papers, partial results) and the excerpt with its matched words marked.
    private var matchLine: AttributedString {
        guard let match = row.match else { return AttributedString("") }
        if row.showsStrength { return SearchMatchLine.line(match.match, excerpt: match.excerpt) }
        guard let excerpt = match.excerpt else { return AttributedString("") }
        return SearchMatchLine.marked(excerpt.text, excerpt.highlights, emphasis: true)
    }
}
