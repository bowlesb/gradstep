import Foundation
import Observation
import ScienceReaderCore

// Global search (docs/architecture/GLOBAL_SEARCH.md; proposal docs/proposals/GLOBAL_SEARCH_AND_MORE.md, B): one field over
// papers (the Library's own index and engine), chats and their messages, kept explanations, snippets, diagrams, the
// Feed's current page, tags and Settings. Everything runs on this device; ML paper search runs only from its own row.

/// The chips under the field (once there is a query): All, a group, or the smaller kinds together.
enum GlobalSearchChip: String, CaseIterable, Identifiable, Sendable {
    case all, papers, chats, explanations, snippets, more
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"; case .papers: "Papers"; case .chats: "Chats"; case .explanations: "Explanations"
        case .snippets: "Snippets"; case .more: "More kinds"
        }
    }
    /// The groups it shows; nil is every group.
    var groups: Set<SearchGroup>? {
        switch self {
        case .all: nil
        case .papers: [.papers]
        case .chats: [.chats]
        case .explanations: [.explanations]
        case .snippets: [.snippets]
        case .more: [.diagrams, .feed, .tags, .settings]
        }
    }
    /// The chip a group's "See all" opens.
    static func showing(_ group: SearchGroup) -> GlobalSearchChip {
        switch group {
        case .papers: .papers
        case .chats: .chats
        case .explanations: .explanations
        case .snippets: .snippets
        case .passages: .all
        default: .more
        }
    }
}

/// Where a result goes when opened (proposal A.5 / B.5's table: each through the route that already exists).
enum GlobalSearchTarget: Hashable, Sendable {
    case paper(UUID, find: String?)
    case passage(paper: UUID, block: String, quote: String)
    case conversation(UUID)
    case message(conversation: UUID, event: UUID)
    case explanation(SearchItemKind, file: String)
    case diagram(UUID)
    case collection(UUID)
    case snippet(collection: UUID, entry: UUID)
    case feed(String)
    case tag(String)
    case setting(String)

    /// Opened beside the results in the Wide shape (a paper, a chat, a collection); the others go to their place.
    var showsBeside: Bool {
        switch self {
        case .paper, .passage, .conversation, .message, .explanation, .collection, .snippet: true
        case .diagram, .feed, .tag, .setting: false
        }
    }
}

/// One result row: fixed shape (a title line and a two-line match line), so rows never jump while typing.
struct GlobalSearchRow: Identifiable, Hashable, Sendable {
    let id: String
    let group: SearchGroup
    let symbol: String
    let title: String
    var titleHighlights: [Range<Int>] = []
    /// "You · 3 days ago", "Equation (7) · Direct Preference Optimization".
    var subtitle: String = ""
    /// The match line: strength (shown for papers, and for partial results) and an excerpt with marked words.
    var match: SearchResultMatch?
    var showsStrength = false
    /// Other matches in the same chat or collection ("+3 more in this chat").
    var more = 0
    let target: GlobalSearchTarget

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.title == b.title && a.subtitle == b.subtitle && a.more == b.more && a.match == b.match }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// "Chat message. ‘…’ In: Why does attention scale. 3 days ago" (proposal A.6).
    var spokenLabel: String {
        var parts = [kindName + ". " + title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let excerpt = match?.excerpt?.text, !excerpt.isEmpty { parts.append(excerpt) }
        if showsStrength, let match { parts.append(match.match.spokenLabel) }
        if more > 0 { parts.append("\(more) more in this \(group == .snippets ? "collection" : "chat")") }
        return parts.joined(separator: ". ")
    }

    var kindName: String {
        switch target {
        case .paper: "Paper"; case .passage: "Passage"; case .conversation: "Chat"; case .message: "Chat message"
        case .explanation(let kind, _): kind == .equation ? "Equation explanation" : kind == .figure ? "Figure explanation" : "Paper explanation"
        case .diagram: "Diagram"; case .collection: "Collection"; case .snippet: "Snippet"; case .feed: "Feed paper"
        case .tag: "Tag"; case .setting: "Setting"
        }
    }

    /// VoiceOver's hint: what opening it does.
    var hint: String {
        switch target {
        case .paper: "Opens the paper"; case .passage: "Opens the paper at this passage"; case .conversation: "Opens the chat"
        case .message: "Opens the chat at this message"; case .explanation: "Opens the explanation in its paper"
        case .diagram: "Opens the diagram"; case .collection: "Opens the collection"; case .snippet: "Opens the snippet"
        case .feed: "Opens the paper's details in the Feed"; case .tag: "Shows your papers with this tag"; case .setting: "Opens Settings at this row"
        }
    }
}

struct GlobalSearchGroup: Identifiable, Equatable, Sendable {
    let group: SearchGroup
    var rows: [GlobalSearchRow]
    /// Every match (rows may be fewer: a group's best three, or a page).
    let total: Int
    /// "24 messages in 9 chats" on a chip's list.
    var summary: String?
    var id: SearchGroup { group }
}

struct GlobalSearchResults: Equatable, Sendable {
    var query = ""
    var chip = GlobalSearchChip.all
    var scope: UUID?
    var groups: [GlobalSearchGroup] = []
    /// No exact matches; these are for the corrected words ("showing attention").
    var correction: String?
    /// No result has every word; these have some ("Results with some of your words").
    var partial = false
    var isEmpty: Bool { groups.isEmpty }
    var total: Int { groups.reduce(0) { $0 + $1.total } }
}

// MARK: - The worker

/// Everything a search reads, captured on the main actor (values; the indexes are actors or sealed stores).
struct GlobalSearchInput: Sendable {
    let id = UUID()
    let query: String
    let chip: GlobalSearchChip
    /// "In this paper": its ID, title and reading (for passages).
    var scope: UUID?
    var scopeReading: ReaderBundleIndex?
    /// Rows per group: three in All, a page on a chip.
    var limit: Int
    var now = Date()
    var everything: EverythingIndex?
    var papers: FullTextIndexStore?
    var candidates: [LibrarySearchCandidate] = []
    var sources = EverythingIndexer.Sources()
    var feed: [DiscoveryResult] = []
    var tags: [(name: String, count: Int)] = []
    var settings: [GlobalSearchSettings.Row] = []
}

enum GlobalSearchEngine {
    /// Rows per group in All.
    static let allRows = 3

    static func run(_ input: GlobalSearchInput) async -> GlobalSearchResults {
        let results = await search(input, text: input.query, partial: false)
        guard !Task.isCancelled, results.isEmpty, !input.query.trimmingCharacters(in: .whitespaces).isEmpty else { return results }
        // Nothing: a word may be a typo (corrected when it matches nothing, over both indexes' words).
        let snapshots = await [try? input.everything?.snapshot().index, try? input.papers?.snapshot()].compactMap { $0 }
        let query = FullTextQuery(input.query)
        var corrected = input.query, changed = false
        for clause in query.clauses where !clause.phrase {
            if let fixed = FullTextTypos.correction(for: clause.text, in: snapshots) {
                corrected = corrected.replacingOccurrences(of: clause.text, with: fixed); changed = true
            }
        }
        if changed {
            var fixed = await search(input, text: corrected, partial: false)
            if !fixed.isEmpty { fixed.correction = corrected.trimmingCharacters(in: .whitespaces); fixed.query = input.query; return fixed }
        }
        // Still nothing, with several words: what has some of them.
        if query.clauses.count >= 2 {
            var some = await search(input, text: input.query, partial: true)
            some.partial = !some.isEmpty
            if !some.isEmpty { return some }
        }
        return results
    }

    /// One pass over every source for `text`.
    static func search(_ input: GlobalSearchInput, text: String, partial: Bool) async -> GlobalSearchResults {
        var results = GlobalSearchResults(query: input.query, chip: input.chip, scope: input.scope)
        let query = FullTextQuery(text)
        guard !query.isEmpty else { return results }
        let wanted = input.chip.groups
        func wants(_ group: SearchGroup) -> Bool { wanted?.contains(group) ?? true }
        let limit = input.chip == .all && input.scope == nil ? allRows : input.limit
        var groups: [GlobalSearchGroup] = []

        // Passages of the open paper ("In this paper").
        if let reading = input.scopeReading, let paper = input.scope, wants(.passages) || input.chip == .all {
            let found = MemorySearch.passages(query, in: reading, limit: input.chip == .all ? 3 : input.limit, isCancelled: { Task.isCancelled })
            if found.total > 0 {
                groups.append(GlobalSearchGroup(group: .passages, rows: found.passages.map { passage in
                    GlobalSearchRow(id: "passage:\(passage.blockID)", group: .passages, symbol: "text.alignleft", title: passage.section ?? "Passage",
                                    match: SearchResultMatch(match: SearchMatch(clauseFields: []), excerpt: passage.excerpt),
                                    target: .passage(paper: paper, block: passage.blockID, quote: passage.excerpt.firstMatch ?? ""))
                }, total: found.total))
            }
        }

        // Papers: the Library's own engine over its encrypted index, so both searches agree.
        if input.scope == nil, wants(.papers), !input.candidates.isEmpty {
            if let group = await papers(input, query: query, text: text, partial: partial, limit: limit) { groups.append(group) }
        }
        if Task.isCancelled { return results }

        // Chats, explanations, snippets, diagrams: the everything index.
        if let index = input.everything, let snapshot = try? await index.snapshot() {
            let options = EverythingSearch.Options(paperID: input.scope, groups: wanted, collapse: input.chip == .all, partial: partial, now: input.now)
            let found = EverythingSearch.search(snapshot, query: query, options: options, isCancelled: { Task.isCancelled })
            let summaries = Dictionary(input.sources.summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for group in found {
                let rows = group.hits.prefix(limit).compactMap { row($0, query: query, sources: input.sources, summaries: summaries, partial: partial) }
                guard !rows.isEmpty || group.total > 0 else { continue }
                var shown = GlobalSearchGroup(group: group.group, rows: rows, total: group.total)
                if group.group == .chats, input.chip != .all {
                    let messages = group.hits.filter { $0.info.kind == .message }.count
                    shown.summary = "\(messages) \(messages == 1 ? "message" : "messages") in \(group.containers) \(group.containers == 1 ? "chat" : "chats")"
                }
                groups.append(shown)
            }
        }
        if Task.isCancelled { return results }

        // In memory: the Feed's current page, tags, Settings.
        if input.scope == nil {
            if wants(.feed) {
                var rows: [GlobalSearchRow] = []
                for result in input.feed {
                    let fields: [(SearchMatchField, String)] = [(.title, result.title), (.abstract, result.abstract ?? ""), (.authors, result.authors.joined(separator: ", ")),
                                                                (.tags, result.reason?.label ?? "")]
                    guard let match = MemorySearch.match(query, fields: fields, partial: partial) else { continue }
                    var shown = SearchResultMatch(match: match, titleHighlights: SearchHighlighter.highlights(query, in: result.title))
                    if let abstract = result.abstract { shown.excerpt = SearchHighlighter.excerpt(query, in: abstract); shown.excerptField = .abstract }
                    rows.append(GlobalSearchRow(id: "feed:\(result.sourceID)", group: .feed, symbol: "dot.radiowaves.up.forward", title: result.title,
                                                titleHighlights: shown.titleHighlights, subtitle: result.authors.prefix(3).joined(separator: ", "),
                                                match: shown, showsStrength: true, target: .feed(result.sourceID)))
                }
                if !rows.isEmpty { groups.append(GlobalSearchGroup(group: .feed, rows: Array(rows.prefix(limit)), total: rows.count)) }
            }
            if wants(.tags), !partial {
                let rows = input.tags.filter { MemorySearch.prefixMatch(text, in: [$0.name]) }.map { tag in
                    GlobalSearchRow(id: "tag:\(tag.name.lowercased())", group: .tags, symbol: "tag", title: tag.name,
                                    titleHighlights: MemorySearch.prefixHighlights(text, in: tag.name),
                                    subtitle: "\(tag.count) \(tag.count == 1 ? "paper" : "papers")", target: .tag(tag.name))
                }
                if !rows.isEmpty { groups.append(GlobalSearchGroup(group: .tags, rows: Array(rows.prefix(limit)), total: rows.count)) }
            }
            if wants(.settings), !partial {
                let rows = input.settings.filter { MemorySearch.prefixMatch(text, in: [$0.title] + $0.synonyms) }.map { row in
                    GlobalSearchRow(id: "setting:\(row.id)", group: .settings, symbol: "gearshape", title: row.title,
                                    titleHighlights: MemorySearch.prefixHighlights(text, in: row.title), subtitle: "Settings › " + row.section,
                                    target: .setting(row.id))
                }
                if !rows.isEmpty { groups.append(GlobalSearchGroup(group: .settings, rows: Array(rows.prefix(limit)), total: rows.count)) }
            }
        }
        results.groups = groups.sorted { $0.group < $1.group }
        return results
    }

    /// The Library's papers matching `query`: its engine (all words, metadata substring rule, BM25F, recency), or, for
    /// partial results, the paper index's papers holding any of the words.
    static func papers(_ input: GlobalSearchInput, query: FullTextQuery, text: String, partial: Bool, limit: Int) async -> GlobalSearchGroup? {
        let byID = Dictionary(input.candidates.filter { $0.id.hasPrefix("paper/") }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [GlobalSearchRow] = []
        var total = 0
        if partial {
            guard let snapshot = try? await input.papers?.snapshot() else { return nil }
            let hits = snapshot.search(query).values.sorted { ($0.clauses.nonzeroBitCount, $0.score) > ($1.clauses.nonzeroBitCount, $1.score) }
            for hit in hits {
                guard let candidate = byID["paper/" + hit.group], let paperID = UUID(uuidString: hit.group) else { continue }
                total += 1
                guard rows.count < limit else { continue }
                let match = SearchMatch(clauseFields: (0..<query.clauses.count).map { hit.strongestField(clause: $0) })
                let shown = LibrarySearchEngine.resultMatch(match, query: query, candidate: candidate, body: snapshot.snippet(for: hit))
                rows.append(paperRow(candidate, paperID: paperID, match: shown, find: shown.excerptField == .fullText ? shown.excerpt?.firstMatch : nil))
            }
        } else {
            let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 0, query: text, sort: .recent)
            let library = LibrarySearchInput(ticket: LibrarySearchTicket(key: key), candidates: input.candidates, fullText: input.papers)
            guard let output = try? await LibrarySearchEngine.run(library) else { return nil }
            for id in output.rowIDs {
                guard let candidate = byID[id], let paperID = UUID(uuidString: String(id.dropFirst("paper/".count))) else { continue }
                total += 1
                guard rows.count < limit else { continue }
                rows.append(paperRow(candidate, paperID: paperID, match: output.matches[id], find: output.snippets[id]?.firstMatch))
            }
        }
        return total > 0 ? GlobalSearchGroup(group: .papers, rows: rows, total: total) : nil
    }

    static func paperRow(_ candidate: LibrarySearchCandidate, paperID: UUID, match: SearchResultMatch?, find: String?) -> GlobalSearchRow {
        GlobalSearchRow(id: "paper:\(paperID.wire)", group: .papers, symbol: "doc.text", title: candidate.title,
                        titleHighlights: match?.titleHighlights ?? [], subtitle: candidate.text(of: .authors) ?? "",
                        match: match, showsStrength: true, target: .paper(paperID, find: find.map { String($0.prefix(200)) }))
    }

    /// A row for an everything-index hit, read from its source (a hit whose source is gone is dropped).
    static func row(_ hit: EverythingSearch.Hit, query: FullTextQuery, sources: EverythingIndexer.Sources,
                    summaries: [UUID: ConversationSummary], partial: Bool) -> GlobalSearchRow? {
        let info = hit.info
        let id = UUID(uuidString: info.id)
        func when(_ date: Date?) -> String? { date.map { ChatHistoryFormat.lastUsed($0) } }
        func made(_ item: SearchItem, title: String, symbol: String, subtitle: [String?], target: GlobalSearchTarget) -> GlobalSearchRow {
            let shown = EverythingSearch.display(item, title: title, query: query, match: hit.match, fieldClauses: hit.fieldClauses)
            return GlobalSearchRow(id: info.group, group: info.kind.group, symbol: symbol, title: title, titleHighlights: shown.titleHighlights,
                                   subtitle: subtitle.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), match: shown,
                                   showsStrength: partial, more: hit.more, target: target)
        }
        switch info.kind {
        case .conversation:
            guard let id, let summary = summaries[id] else { return nil }
            let item = SearchItem.conversation(id: id, title: EverythingIndexer.ownTitle(summary), paperID: summary.documentID,
                                               paperTitle: summary.documentID.flatMap { sources.paperTitles[$0] }, passage: summary.anchor?.quote, date: nil)
            return made(item, title: summary.title, symbol: "bubble.left.and.bubble.right",
                        subtitle: [summary.documentID.flatMap { sources.paperTitles[$0] }, when(summary.lastUsedAt)], target: .conversation(id))
        case .message:
            guard let id, let event = sources.state.events[id], let text = event.payload.text, let conversation = info.container,
                  let summary = summaries[conversation] else { return nil }
            let item = SearchItem.message(eventID: id, conversationID: conversation, paperID: info.paperID, text: text,
                                          byReader: event.payload.role == .user, date: nil)
            return made(item, title: summary.title, symbol: event.payload.role == .user ? "person.crop.circle" : "text.bubble",
                        subtitle: [event.payload.role == .user ? "You" : "Answer", when(event.payload.createdDate ?? summary.lastUsedAt)],
                        target: .message(conversation: conversation, event: id))
        case .diagram:
            guard let id, let event = sources.state.revisions(for: id).first, let diagram = ChatDiagram.decode(event.payload.text) else { return nil }
            let item = SearchItem.diagram(id: id, diagram: diagram, conversationID: nil, paperID: nil, date: nil)
            return made(item, title: diagram.title, symbol: "point.3.connected.trianglepath.dotted",
                        subtitle: [event.payload.conversationID.flatMap { summaries[$0]?.title }], target: .diagram(id))
        case .equation, .figure, .paperExplainer:
            let store = info.kind == .equation ? sources.equations : info.kind == .figure ? sources.figures : sources.explainers
            guard let store, let item = ExplanationCache.shared.item(info.kind, id: info.id, store: store) else { return nil }
            let parts = item.title.components(separatedBy: " · ")
            let label = parts.first ?? item.title, paper = parts.dropFirst().joined(separator: " · ")
            let symbol = info.kind == .equation ? "function" : info.kind == .figure ? "photo" : "sparkles"
            return made(item, title: label, symbol: symbol, subtitle: [paper, when(info.date)], target: .explanation(info.kind, file: info.id))
        case .collection:
            guard let id, let note = sources.notes.note(id) else { return nil }
            let item = SearchItem.collection(id: id, name: note.title, date: nil)
            return made(item, title: note.title, symbol: "folder", subtitle: [NoteCollectionLine.detail(entryCount: note.entries.count)],
                        target: .collection(id))
        case .snippet:
            guard let id, let found = sources.notes.entry(id) else { return nil }
            let record = found.entry.record
            var extra: [String] = []
            if let anchor = record.anchor, let manifest = anchor.manifestSHA256, let reading = sources.readings[manifest] {
                extra = NoteSearch.bundleText(anchor, in: reading)
            }
            let item = SearchItem.snippet(record, collection: found.note.title, paperID: nil, extra: extra,
                                          recognised: record.media.flatMap { sources.recognised[$0.full.blobID] }, date: nil)
            let title = [record.comment, record.quote ?? "", record.source?.label ?? "", record.source?.section ?? ""]
                .first { !$0.isEmpty }.map { String($0.split(whereSeparator: \.isNewline).first ?? "") } ?? "Snippet"
            return made(item, title: String(title.prefix(120)), symbol: "scissors", subtitle: [found.note.title, record.source?.title],
                        target: .snippet(collection: found.note.id, entry: id))
        }
    }
}

/// Kept explanations read for rows (one sealed read each), the most recent kept in memory; cleared at sign-out.
final class ExplanationCache: @unchecked Sendable {
    static let shared = ExplanationCache()
    private let lock = NSLock()
    private var items: [String: SearchItem] = [:]
    private var order: [String] = []

    func item(_ kind: SearchItemKind, id: String, store: EquationResultStore) -> SearchItem? {
        let key = "\(kind.rawValue):\(id)"
        if let hit = lock.withLock({ items[key] }) { return hit }
        guard let item = EverythingIndexer.explanation(kind, id: id, store: store) else { return nil }
        lock.withLock {
            items[key] = item; order.append(key)
            while order.count > 64 { items[order.removeFirst()] = nil }
        }
        return item
    }

    func removeAll() { lock.withLock { items = [:]; order = [] } }
}

/// One search at a time; the latest input waits; a result is published only for the input that is still current
/// (`LibrarySearchCoordinator`'s pattern, without a debounce: the indexes answer in milliseconds).
@MainActor
final class GlobalSearchCoordinator {
    private struct Running { let id: UUID; let task: Task<GlobalSearchResults, Never> }
    private var running: Running?
    private var pending: GlobalSearchInput?
    private var current: UUID?
    private let publish: @MainActor (GlobalSearchResults) -> Void

    init(publish: @escaping @MainActor (GlobalSearchResults) -> Void) { self.publish = publish }

    func submit(_ input: GlobalSearchInput) {
        current = input.id
        pending = input
        running?.task.cancel()
        startIfIdle()
    }

    func invalidate() { current = nil; pending = nil; running?.task.cancel() }

    var isBusy: Bool { running != nil || pending != nil }

    private func startIfIdle() {
        guard running == nil, let input = pending else { return }
        pending = nil
        let task = Task.detached(priority: .userInitiated) { await GlobalSearchEngine.run(input) }
        running = Running(id: input.id, task: task)
        Task { @MainActor [weak self] in
            let results = await task.value
            guard let self, self.running?.id == input.id else { return }
            self.running = nil
            if self.current == input.id && !task.isCancelled { self.publish(results) }
            self.startIfIdle()
        }
    }
}

// MARK: - The screen's state

@MainActor @Observable
final class GlobalSearchModel {
    /// Rows a chip's list adds at a time.
    static let pageSize = 50

    var query = "" { didSet { if query != oldValue { limit = Self.pageSize; submit() } } }
    var chip = GlobalSearchChip.all { didSet { if chip != oldValue { limit = Self.pageSize; submit() } } }
    /// "In this paper": the paper's ID and title (the field's removable token).
    private(set) var scope: (id: UUID, title: String)?
    private(set) var results = GlobalSearchResults()
    /// A search for the current words is running (its results not in yet).
    private(set) var searching = false
    private(set) var recentSearches: [String] = []
    private(set) var recentItems: [GlobalSearchRow] = []
    /// The everything index's first build (0…1), nil when it is ready.
    var indexing: Double?
    /// Wide: the result shown beside the list.
    var picked: GlobalSearchRow?
    /// The temporary presentation until the navigation's `.search` place takes it (see `ReaderModel.openGlobalSearch`).
    var shown = false
    /// Bumped to bring the keyboard up (the field focuses when the screen appears with no words).
    private(set) var focusRequest = UUID()
    private(set) var limit = pageSize
    @ObservationIgnored weak var reader: ReaderModel?
    /// Your tags and their counts, made once per library size (`ReaderModel.globalSearchTags`).
    @ObservationIgnored var tagsCache: (papers: Int, tags: [(name: String, count: Int)])?
    @ObservationIgnored private lazy var coordinator = GlobalSearchCoordinator { [weak self] results in self?.received(results) }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func open(scope paper: (id: UUID, title: String)?) {
        scope = paper
        picked = nil
        if trimmedQuery.isEmpty { focusRequest = UUID() }
        submit()
        loadRecents()
    }

    func removeScope() { scope = nil; submit() }

    /// A chip's list reached its end: the next page.
    func showMore() {
        guard chip != .all, results.groups.contains(where: { $0.rows.count < $0.total }) else { return }
        limit += Self.pageSize
        submit()
    }

    /// The index or the sources changed: a showing search runs again (rows keep their places; no blanking).
    func sourcesChanged() { if shown && !trimmedQuery.isEmpty { submit() } }

    func submit() {
        guard let reader, !trimmedQuery.isEmpty || scope != nil else {
            coordinator.invalidate(); results = GlobalSearchResults(); searching = false; return
        }
        guard !trimmedQuery.isEmpty else { coordinator.invalidate(); results = GlobalSearchResults(query: "", scope: scope?.id); searching = false; return }
        searching = true
        coordinator.submit(reader.globalSearchInput(query: query, chip: chip, scope: scope?.id, limit: limit))
    }

    private func received(_ results: GlobalSearchResults) {
        searching = coordinator.isBusy
        guard results.query == query else { return }
        self.results = results
    }

    /// Remembers the words (sealed beside the index) when a result is opened or Return is pressed.
    func remember() {
        guard let index = reader?.everythingIndexer.index, !trimmedQuery.isEmpty else { return }
        recentSearches = Array(index.remember(trimmedQuery).prefix(5))
    }

    func clearRecentSearches() {
        reader?.everythingIndexer.index?.clearRecentSearches()
        recentSearches = []
    }

    func loadRecents() {
        recentSearches = Array((reader?.everythingIndexer.index?.recentSearches() ?? []).prefix(5))
        Task { [weak self] in
            guard let self, let reader = self.reader else { return }
            self.recentItems = await reader.globalSearchRecentItems()
        }
    }

    /// Sign-out: nothing of the old account stays on screen or in memory.
    func reset() {
        coordinator.invalidate()
        query = ""; chip = .all; scope = nil; results = GlobalSearchResults(); searching = false
        recentSearches = []; recentItems = []; picked = nil; shown = false; indexing = nil; limit = Self.pageSize; tagsCache = nil
        ExplanationCache.shared.removeAll()
    }
}
