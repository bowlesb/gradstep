import Foundation
import ScienceReaderCore

/// A search result's message: the chat opens scrolled to it, which is marked for a moment.
struct ChatLanding: Equatable {
    let conversationID: UUID
    let eventID: UUID
    let token = UUID()
}

// Global search (docs/architecture/GLOBAL_SEARCH.md): entry points, what a search reads, and where each result opens.
extension ReaderModel {
    func configureGlobalSearch() {
        globalSearch.reader = self
        everythingIndexer.sources = { [weak self] in self?.everythingSources() ?? .init() }
        everythingIndexer.changed = { [weak self] in self?.globalSearch.sourcesChanged() }
        everythingIndexer.progress = { [weak self] value in self?.globalSearch.indexing = value }
        notes.recognisedChanged = { [weak self] in self?.everythingIndexer.noteChange() }
        #if DEBUG && FIXTURE_HOST
        // Without a fixture account (whose activation opens it when ready), a moment after launch.
        if !ProcessInfo.processInfo.arguments.contains("--draft-fixture") {
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(600)); self?.openGlobalSearchIfAskedAtLaunch() }
        }
        #endif
    }

    #if DEBUG && FIXTURE_HOST
    /// `--global-search[=words]` (and `--global-search-scoped`): the Search place at launch, with those words (UI tests and
    /// screenshots).
    func openGlobalSearchIfAskedAtLaunch() {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0 == "--global-search" || $0.hasPrefix("--global-search=") }) else { return }
        openGlobalSearch(scopePaper: ProcessInfo.processInfo.arguments.contains("--global-search-scoped") ? selectedPaper?.id : nil)
        if let words = argument.split(separator: "=", maxSplits: 1).dropFirst().first { globalSearch.query = String(words) }
    }
    #endif

    /// Opens global search (⌘K, the bar's 🔍, Wide's 🔍, the Mac's toolbar field, a paper's "Search in this paper"): the
    /// Search place (`ReaderTab.search`, every shape), scoped to a paper when given. Reading mode (the paper alone, no
    /// places) ends first.
    func openGlobalSearch(scopePaper: Paper.ID? = nil) {
        let paper = scopePaper.flatMap { id in papers.first { $0.id == id } ?? (selectedPaper?.id == id ? selectedPaper : nil) }
        globalSearch.open(scope: paper.map { ($0.id, $0.title) })
        exitReadingMode()
        if tab != .search { placeBeforeSearch = tab }
        tab = .search
    }

    /// Cancel (and Escape): back to the place Search was opened from; the words stay for the next 🔍.
    func closeGlobalSearch() {
        globalSearch.picked = nil
        if tab == .search { tab = placeBeforeSearch }
    }

    // MARK: What a search reads

    /// The sources as values, for the indexer's pass and a search's rows.
    func everythingSources() -> EverythingIndexer.Sources {
        var sources = EverythingIndexer.Sources()
        sources.state = privateState
        sources.summaries = conversationSummaries
        sources.notes = notes.state
        var titles: [UUID: String] = [:], byMembership: [UUID: UUID] = [:], byArxiv: [String: UUID] = [:]
        var readings: [String: ReaderBundleIndex] = [:]
        for paper in papers {
            titles[paper.id] = paper.title
            if let membership = paper.sourceMembership?.membershipID { byMembership[membership] = paper.id }
            if let source = paper.sourceID { byArxiv[source] = paper.id }
            if let bundle = paper.readerBundle { readings[bundle.manifestSHA256] = bundle.index }
        }
        if let selectedPaper, let bundle = selectedPaper.readerBundle { readings[bundle.manifestSHA256] = bundle.index }
        sources.paperTitles = titles
        sources.readings = readings
        for note in notes.state.notes {
            for entry in note.entries {
                guard let source = entry.record.source else { continue }
                let paper = source.membershipID.flatMap { byMembership[$0] }
                    ?? (source.kind == .arxiv ? source.sourceID.flatMap { byArxiv[$0] } : nil)
                    ?? (source.kind == .document ? source.sourceID.flatMap(UUID.init(uuidString:)).flatMap { titles[$0] != nil ? $0 : nil } : nil)
                if let paper { sources.notePapers[entry.id] = paper }
            }
        }
        sources.recognised = notes.recognised
        sources.equations = equationResultStore(); sources.figures = figureResultStore(); sources.explainers = paperExplainerResultStore()
        return sources
    }

    /// One search's input: the words, chip, scope and page, and everything it reads (captured now, as values).
    func globalSearchInput(query: String, chip: GlobalSearchChip, scope: UUID?, limit: Int) -> GlobalSearchInput {
        var input = GlobalSearchInput(query: query, chip: chip, limit: limit)
        input.everything = everythingIndexer.index
        input.papers = fullTextIndexer.store
        input.candidates = librarySearchCandidates
        input.sources = everythingSources()
        if let scope {
            input.scope = scope
            input.scopeReading = (papers.first { $0.id == scope } ?? (selectedPaper?.id == scope ? selectedPaper : nil))?.readerBundle?.index
        } else {
            input.feed = shownFeedResults
            input.tags = globalSearchTags()
            input.settings = GlobalSearchSettings.visible(self)
        }
        return input
    }

    /// Your tags with how many papers carry each, as the Library shows them.
    func globalSearchTags() -> [(name: String, count: Int)] {
        if let cached = globalSearch.tagsCache, cached.papers == papers.count { return cached.tags }
        var counts: [String: (name: String, count: Int)] = [:]
        for paper in papers where !paper.isSample {
            for tag in LibraryTags.tags(for: paper) { counts[tag.lowercased(), default: (tag, 0)].count += 1 }
        }
        let tags = counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        globalSearch.tagsCache = (papers.count, tags)
        return tags
    }

    /// The empty screen's "Recently opened": papers read here, chats used, collections edited, explanations kept, newest
    /// first (data the app already has; nothing new is recorded).
    func globalSearchRecentItems() async -> [GlobalSearchRow] {
        var dated: [(Date, GlobalSearchRow)] = []
        for paper in papers where !paper.isSample {
            guard let opened = readingActivity[paper.id]?.openedAt else { continue }
            dated.append((opened, GlobalSearchRow(id: "recent.paper:\(paper.id.wire)", group: .papers, symbol: "doc.text", title: paper.title,
                                                  subtitle: paper.authors, target: .paper(paper.id, find: nil))))
        }
        let titles = Dictionary(papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for summary in conversationSummaries {
            guard let used = summary.lastUsedAt else { continue }
            dated.append((used, GlobalSearchRow(id: "recent.chat:\(summary.id.wire)", group: .chats, symbol: "bubble.left.and.bubble.right",
                                                title: summary.title, subtitle: summary.documentID.flatMap { titles[$0] } ?? "General chat",
                                                target: .conversation(summary.id))))
        }
        for note in notes.state.notes {
            let edited = Date(timeIntervalSince1970: Double(note.lastEdited) / 1_000)
            dated.append((edited, GlobalSearchRow(id: "recent.collection:\(note.id.wire)", group: .snippets, symbol: "folder", title: note.title,
                                                  subtitle: NoteCollectionLine.detail(entryCount: note.entries.count),
                                                  target: .collection(note.id))))
        }
        // Explanations: the newest few files, opened for their subjects (off the main actor).
        let stores: [(SearchItemKind, EquationResultStore?)] = [(.equation, equationResultStore()), (.figure, figureResultStore()), (.paperExplainer, paperExplainerResultStore())]
        let explanations = await Task.detached(priority: .userInitiated) { () -> [(Date, GlobalSearchRow)] in
            var out: [(Date, GlobalSearchRow)] = []
            for (kind, store) in stores {
                guard let store else { continue }
                for stamp in store.fileStamps().sorted(by: { $0.modified > $1.modified }).prefix(3) {
                    let id = String(stamp.fileName.dropLast(".sealed".count))
                    guard let item = ExplanationCache.shared.item(kind, id: id, store: store) else { continue }
                    let parts = item.title.components(separatedBy: " · ")
                    out.append((stamp.modified, GlobalSearchRow(id: "recent.\(kind.rawValue):\(id)", group: .explanations,
                        symbol: kind == .equation ? "function" : kind == .figure ? "photo" : "sparkles", title: parts.first ?? item.title,
                        subtitle: parts.dropFirst().joined(separator: " · "), target: .explanation(kind, file: id))))
                }
            }
            return out
        }.value
        dated += explanations
        return dated.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
    }

    // MARK: Opening a result (proposal B.5's table; each through its existing route)

    /// Opens `row` where it lives. Wide: a paper, chat or collection shows beside the results (the list stays); anything
    /// else goes to its place, as on iPhone, where 🔍 brings back the same words and chip.
    func openSearchResult(_ row: GlobalSearchRow, wide: Bool = false) {
        globalSearch.remember()
        switch row.target {
        case .paper(let id, let find):
            guard let paper = papers.first(where: { $0.id == id }) else { error = "This paper isn’t in your library on this device."; return }
            pendingPaperFind = find.map { PendingPaperFind(paperID: id, text: $0) }
            select(paper)
        case .passage(let paperID, let block, let quote):
            guard let paper = papers.first(where: { $0.id == paperID }) ?? (selectedPaper?.id == paperID ? selectedPaper : nil) else { return }
            if selectedPaper?.id != paper.id || selectedPaper?.artifactID != paper.artifactID { select(paper) }
            referenceNotice = nil
            var request = PaperPassageRequest(documentID: paper.id, conversationID: UUID(),
                                              anchor: TextAnchor(manifestSHA256: paper.readerBundle?.manifestSHA256, quote: quote, elementID: block))
            request.origin = .note
            passageRequest = request
            if !quote.isEmpty { pendingPaperFind = PendingPaperFind(paperID: paper.id, text: quote) }
            showPaperPlace()
        case .conversation(let id):
            openConversation(id)
        case .message(let conversation, let event):
            openConversation(conversation)
            // The message may be on another branch than the one shown: show the branch that holds it.
            if !chatMessages.contains(where: { $0.id == event }),
               let branch = chatBranches.first(where: { $0.messages.contains { $0.id == event } }) {
                activeBranchID = branch.head
            }
            chatLanding = ChatLanding(conversationID: conversation, eventID: event)
        case .explanation(let kind, let file):
            let store = kind == .equation ? equationResultStore() : kind == .figure ? figureResultStore() : paperExplainerResultStore()
            let subject: ExplanationSubject? = switch kind {
            case .equation: store?.read(fileName: file + ".sealed", as: EquationAnswer.self)?.subject
            case .figure: store?.read(fileName: file + ".sealed", as: FigureAnswer.self)?.subject
            default: store?.read(fileName: file + ".sealed", as: PaperExplainerAnswer.self)?.subject
            }
            guard let subject else { return }
            if kind == .paperExplainer, let paper = papers.first(where: { $0.id == subject.paperID }) {
                select(paper); openPaperExplainer(paper, requesting: false)
            } else if !openExplanation(subject) {
                // The reader's sample (Settings' list leaves it out; a search finds what was explained in it too).
                guard let sample = papers.first(where: { $0.id == subject.paperID }) else {
                    error = "The paper this explanation is about isn’t in your library on this device."; return
                }
                pendingLocalAIChoice = .some(subject.localModelID)
                pendingExplanation = subject
                select(sample)
            }
        case .diagram(let id):
            openDiagram(id)
        case .collection(let id):
            openNote(id)
        case .snippet(let collection, let entry):
            openNote(collection, entry: entry)
        case .feed(let source):
            guard let result = shownFeedResults.first(where: { $0.sourceID == source }) ?? feedResults.first(where: { $0.sourceID == source }) else { return }
            tab = .feed
            if compactLayout { feedDetail = result } else { feedPickID = source; feedReading = false }
        case .tag(let name):
            showLibraryPapers(taggedWith: name)
        case .setting(let id):
            openSettings()
            settingsFocus = SettingsFocus(row: id)
        }
        // 🔍 brings the list back at this row (GlobalSearchView scrolls to it).
        globalSearch.returnRowID = row.id
        // Wide: the routes above moved to the result's place; Search stays the place, with the result beside the list.
        // Otherwise the result's place is showing (a Setting opens over Search, whose words wait under it).
        if wide && row.target.showsBeside { tab = .search; globalSearch.picked = row } else { globalSearch.picked = nil }
    }

    /// Return in the field: the row chosen with ↑/↓, else the first result.
    func openChosenGlobalSearchResult(wide: Bool) {
        globalSearch.remember()
        if let row = globalSearch.keyboardRow ?? globalSearch.results.groups.first?.rows.first { openSearchResult(row, wide: wide) }
    }

    /// The last row: ML paper search for the words, exactly as the Library's switch runs it.
    func searchMLPapersFromGlobalSearch() {
        let words = globalSearch.trimmedQuery
        guard !words.isEmpty else { return }
        globalSearch.remember()
        globalSearch.picked = nil
        searchPapers(words)
    }
}
