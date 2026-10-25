import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// The shared paper table (owner request 2026-10-06): which columns fit a width, header sorting, and the Library's
/// and Feed's columns and values. Widths are the row width inside the 16 pt margins.
@MainActor
final class PaperTableTests: XCTestCase {
    private enum Width {
        static let browseColumn: CGFloat = 350 - 32
        static let phoneSmall: CGFloat = 390 - 32        // iPhone 17e portrait
        static let phone: CGFloat = 402 - 32             // iPhone 17 Pro portrait
        static let phoneMax: CGFloat = 440 - 32          // iPhone 17 Pro Max portrait
        static let phoneLandscape: CGFloat = 874 - 124 - 32 // iPhone 17 Pro landscape, inside the safe area
        static let padPortrait: CGFloat = 834 - 32       // iPad Pro 11"
        static let padLandscape: CGFloat = 1210 - 32
    }

    private func libraryColumns(_ width: CGFloat, scale: CGFloat = 1, _ enabled: Set<LibraryTableColumn>) -> [String] {
        PaperTableLayout.visibleColumns(LibraryTableColumn.columns(enabled), width: width, scale: scale).map(\.id)
    }

    private func feedColumns(_ width: CGFloat, scale: CGFloat = 1) -> [String] {
        PaperTableLayout.visibleColumns(FeedTableColumn.all, width: width, scale: scale).map(\.id)
    }

    func testLibraryDefaultColumnsFollowTheWidth() {
        for enabled in [LibraryColumnSettings.compactDefault, LibraryColumnSettings.regularDefault] {
            XCTAssertTrue(enabled.isSuperset(of: [.device, .authors]))
            for width in [Width.phoneSmall, Width.phone, Width.phoneMax, Width.phoneLandscape, Width.padPortrait, Width.padLandscape] {
                let layout = PaperTableLayout.arrangement(LibraryTableColumn.columns(enabled), width: width, scale: 1, scrolling: true)
                XCTAssertEqual(Set(layout.columns + layout.pinned), Set(enabled.map(\.rawValue)), "All chosen metadata is reachable at \(width)")
            }
        }
        XCTAssertEqual(LibraryTableColumn.allCases.last, .progress)
    }

    /// The reader's choice is a ceiling: the width only ever leaves chosen columns out, never adds others.
    func testTurnedOffColumnsNeverShowAndAnyOneColumnFitsBesideProgressOnPhones() {
        var subsets: [Set<LibraryTableColumn>] = [[], Set(LibraryTableColumn.allCases)]
        for column in LibraryTableColumn.allCases {
            subsets.append([column]); subsets.append(Set(LibraryTableColumn.allCases).subtracting([column]))
        }
        for enabled in subsets {
            for width in [Width.browseColumn, Width.phoneSmall, Width.phone, Width.phoneLandscape, Width.padPortrait, Width.padLandscape, 2000] {
                let shown = Set(libraryColumns(width, enabled))
                XCTAssertTrue(shown.isSubset(of: Set(enabled.map(\.rawValue))), "\(shown) beyond \(enabled) at \(width)")
            }
        }
        XCTAssertEqual(libraryColumns(Width.padLandscape, [.pages, .source, .progress]), ["source", "pages", "progress"], "Row order")
        XCTAssertEqual(libraryColumns(Width.padLandscape, []), [], "Title alone")
        // A phone shows whatever short column the reader picks next to Progress (Year off, Added on, say).
        for column in LibraryTableColumn.allCases where ![.progress, .tags, .venue, .authors].contains(column) {
            XCTAssertEqual(libraryColumns(Width.phone, [column, .progress]), [column.rawValue, "progress"], column.rawValue)
            if column != .source {
                XCTAssertEqual(libraryColumns(Width.phoneSmall, [column, .progress]), [column.rawValue, "progress"], "17e: \(column)")
            }
        }
        XCTAssertEqual(libraryColumns(Width.phone, [.tags]), ["tags"], "Tags fits a phone without Progress")
    }

    func testColumnChoicesPersistPerWidthClass() throws {
        let suite = "PaperTableTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LibraryColumnSettings.load(from: defaults), LibraryColumnSettings(), "Defaults before any choice")
        XCTAssertEqual(LibraryColumnSettings()[.compact], [.device, .authors, .year, .added, .opened, .chats, .progress])
        XCTAssertEqual(LibraryColumnSettings()[.regular], [.device, .authors, .year, .tags, .added, .opened, .chats, .progress])

        var settings = LibraryColumnSettings()
        settings[.compact] = [.added, .progress]
        settings[.regular].insert(.source); settings[.regular].remove(.chats)
        settings.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: "library.columns.compact"), "added,progress", "Saved in row order")
        let loaded = LibraryColumnSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded[.regular], [.device, .authors, .year, .tags, .source, .added, .opened, .progress], "iPad keeps its own choice")

        settings[.compact] = []
        settings.save(to: defaults)
        XCTAssertEqual(LibraryColumnSettings.load(from: defaults)[.compact], [], "All off is a choice (the title alone), not the defaults")
        defaults.set("year,topics,progress,", forKey: "library.columns.regular")
        XCTAssertEqual(LibraryColumnSettings.load(from: defaults)[.regular], [.year, .progress], "Unknown names are ignored")
    }

    func testSeparateMetadataAppearsOnceForExistingColumnChoices() throws {
        let suite = "PaperTableTests.columns.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("year,progress", forKey: "library.columns.compact")
        var columns = LibraryColumnSettings.load(from: defaults)
        XCTAssertEqual(columns[.compact], [.device, .authors, .year, .progress])
        columns[.compact].remove(.authors); columns.save(to: defaults)
        XCTAssertFalse(LibraryColumnSettings.load(from: defaults)[.compact].contains(.authors), "A later explicit choice is respected")
    }

    func testDetailedRowsBecomeTheTableAndTheTableIsTheDefault() {
        XCTAssertEqual(LibraryLayout(saved: nil), .table, "The table is the Library's main view")
        XCTAssertEqual(LibraryLayout(saved: "detailed"), .table, "Detailed rows (removed) open the table")
        XCTAssertEqual(LibraryLayout(saved: "table"), .table)
        XCTAssertEqual(LibraryLayout(saved: "list"), .list, "An explicit List stays")
        XCTAssertEqual(LibraryLayout.allCases.map(\.title), ["Table", "List"])
    }

    func testTheFeedOpensAsATableLikeTheLibrary() {
        XCTAssertEqual(FeedLayout(saved: nil), .table, "The Feed's default is the table (owner, 2026-10-24)")
        XCTAssertEqual(FeedLayout(saved: "table"), .table)
        XCTAssertEqual(FeedLayout(saved: "list"), .list, "An explicit List stays")
    }

    func testFeedColumnsFollowTheWidth() {
        // Owner, 2026-10-24: Why first beside the title (every iPhone in portrait), then Popularity (build 21), Topics
        // (chips), Published; the rest scroll sideways.
        XCTAssertEqual(feedColumns(Width.phoneSmall), ["why", "add"], "Phone portrait: title, why and Add")
        XCTAssertEqual(feedColumns(Width.phone), ["why", "add"])
        XCTAssertEqual(feedColumns(Width.phoneLandscape), ["why", "popularity", "add"])
        XCTAssertEqual(feedColumns(Width.padPortrait), ["why", "popularity", "topic", "add"])
        XCTAssertEqual(PaperTableLayout.visibleColumns(FeedTableColumn.columns(Set(FeedTableColumn.choosable), reasons: false),
                                                       width: Width.padPortrait).map(\.id), ["popularity", "topic", "published", "add"],
                       "a category's papers have no reasons: no Why column, the others as before")
    }

    func testChosenColumnsRemainReachableWithoutMovingPinnedControls() {
        let library = PaperTableLayout.arrangement(LibraryTableColumn.columns(LibraryColumnSettings.compactDefault),
                                                    width: Width.phone, scrolling: true)
        XCTAssertEqual(library.columns, ["device", "progress", "authors", "year", "added", "opened", "chats"])
        XCTAssertTrue(library.scrolls)
        XCTAssertEqual(library.titleWidth, 155)
        XCTAssertEqual(library.regionWidth, 203)
        XCTAssertEqual(library.extent, 423)
        XCTAssertEqual(library.snapOffsets, [0, 60, 172, 352, 404, 423])
        let feed = PaperTableLayout.arrangement(FeedTableColumn.columns(Set(FeedTableColumn.choosable)),
                                               width: Width.phoneSmall, scrolling: true)
        XCTAssertEqual(feed.pinned, ["add"])
        XCTAssertEqual(Set(feed.columns), Set(FeedTableColumn.choosable.map(\.rawValue)))
        XCTAssertEqual(feed.regionWidth + (feed.titleWidth ?? 0) + 56 + 24, Width.phoneSmall)
        XCTAssertLessThanOrEqual(feed.columnWidth(260), feed.regionWidth, "Even the Abstract cell is readable in its viewport")
        let chat = ChatTableLayout.arrangement(Set(ChatTableLayout.choosable), width: Width.phoneSmall)
        XCTAssertEqual(chat.pinned, ["lastUsed"])
        XCTAssertEqual(Set(chat.columns), Set(ChatTableLayout.choosable.map(\.rawValue)))
        XCTAssertEqual(chat.regionWidth + (chat.titleWidth ?? 0) + 88 + 24, Width.phoneSmall)
        XCTAssertFalse(PaperTableLayout.arrangement(FeedTableColumn.columns([]), width: Width.phoneSmall, scrolling: true).scrolls)
    }

    func testColumnChoicesKeepEmptyChoicesAndIgnoreRemovedNames() throws {
        let name = "TableColumnChoices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var choice = ColumnChoice<FeedTableColumn>(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault,
                                                  regularDefault: FeedTableColumn.regularDefault)
        choice.compact = []; choice.regular = [.authors, .arxiv]
        choice.save(to: defaults)
        let restored = ColumnChoice<FeedTableColumn>.load(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault,
                                                        regularDefault: FeedTableColumn.regularDefault, from: defaults)
        XCTAssertEqual(restored, choice)
        defaults.set("authors,unknown", forKey: "feed.columns.compact")
        XCTAssertEqual(ColumnChoice<FeedTableColumn>.load(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault,
                                                        regularDefault: FeedTableColumn.regularDefault, from: defaults).compact, [.authors])
    }

    func testOneWideChosenColumnKeepsItsPinnedRegionWithoutArtificialScrolling() {
        let feed = PaperTableLayout.arrangement(FeedTableColumn.columns([.abstract]), width: Width.phoneSmall, scrolling: true)
        XCTAssertEqual(feed.columns, ["abstract"])
        XCTAssertEqual(feed.pinned, ["add"])
        XCTAssertTrue(feed.usesColumnRegion, "The narrowed cell still needs aligned title and Add columns")
        XCTAssertFalse(feed.scrolls, "One cell can be read without an empty horizontal scroll")
        XCTAssertEqual(feed.columnWidth(260), feed.regionWidth)
        let chats = ChatTableLayout.arrangement([.answerLength], width: Width.phoneSmall)
        XCTAssertTrue(chats.usesColumnRegion)
        XCTAssertFalse(chats.scrolls)
        XCTAssertEqual(chats.pinned, ["lastUsed"])
        XCTAssertEqual(chats.columnWidth(104), chats.regionWidth)
    }

    func testTitleKeepsItsShareAndWideningOnlyAddsColumns() {
        checkFitAndGrowth(LibraryTableColumn.columns(Set(LibraryTableColumn.allCases)))
        checkFitAndGrowth(LibraryTableColumn.columns(LibraryColumnSettings.compactDefault))
        checkFitAndGrowth(FeedTableColumn.all)
    }

    private func checkFitAndGrowth<Key>(_ columns: [PaperTableColumn<Key>], file: StaticString = #filePath, line: UInt = #line) {
        var previous = Set<String>()
        for width in stride(from: CGFloat(100), through: 1600, by: 7) {
            for scale in [CGFloat(1), 1.2, 1.5] {
                let visible = PaperTableLayout.visibleColumns(columns, width: width, scale: scale)
                guard !visible.isEmpty else { continue }
                let columnsWidth = visible.reduce(0) { $0 + PaperTableLayout.spacing + $1.width * scale }
                XCTAssertGreaterThanOrEqual(width - columnsWidth + 0.001, PaperTableLayout.titleWidth(in: width, scale: scale),
                                            "The title keeps its share and nothing overflows at \(width) × \(scale)", file: file, line: line)
            }
            let ids = Set(PaperTableLayout.visibleColumns(columns, width: width).map(\.id))
            XCTAssertTrue(previous.isSubset(of: ids), "Widening to \(width) dropped \(previous.subtracting(ids))", file: file, line: line)
            previous = ids
        }
    }

    func testHeaderTapsSortThenReverse() {
        let columns = Dictionary(uniqueKeysWithValues: (LibraryTableColumn.columns(Set(LibraryTableColumn.allCases)) + [LibraryTableColumn.title])
            .map { ($0.id, $0) })
        var sort = PaperTableSort(key: LibrarySearchSort.Field.recent, ascending: false)
        sort = sort.tapping(columns["year"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .year, ascending: false), "Year starts newest first")
        sort = sort.tapping(columns["year"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .year, ascending: true), "Tapping again reverses")
        sort = sort.tapping(columns["title"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .title, ascending: true), "Title starts A to Z")
        sort = sort.tapping(columns["progress"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .progress, ascending: false), "Most read first")
        XCTAssertEqual(sort.tapping(columns["tags"]!), PaperTableSort(key: .tags, ascending: true), "Tags A to Z")
        XCTAssertEqual(sort.tapping(columns["pages"]!), PaperTableSort(key: .pages, ascending: false), "Longest first")
        XCTAssertEqual(sort.tapping(columns["source"]!), PaperTableSort(key: .source, ascending: true))
        XCTAssertEqual(sort.tapping(PaperTableColumn(id: "x", title: "")), sort, "A column without a sort leaves the order alone")
        // Each sortable header starts in the direction the Sort menu uses for that field.
        for column in columns.values {
            guard let field = column.sortKey else { continue }
            XCTAssertEqual(column.ascendingFirst, field.defaultAscending, column.id)
        }
        XCTAssertEqual(Set(columns.values.compactMap(\.sortKey)), Set(LibrarySearchSort.Field.allCases),
                       "Authors has its own sortable header")
    }

    // MARK: Library values

    func testLibraryValuesAndSpokenRow() {
        let now = Date(timeIntervalSince1970: 1_791_201_600)
        var paper = Paper(id: UUID(), title: "Attention Is All You Need", authors: "", year: 2017, abstract: "", keywords: [],
                          fileURL: nil, artifactID: nil)
        paper.authorNames = ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"]
        let facts = LibraryRowFacts(id: "paper/x", title: paper.title, paper: paper, authors: "Vaswani, Shazeer +1", year: 2017,
            tags: ["Language", "Machine learning"], added: now, opened: nil, progress: 0.6, chats: 2, pages: 15, status: .info("Not downloaded"),
            needsCredits: false, source: "1706.03762", spokenSource: "arXiv 1706.03762")
        let item = LibraryTableItem(entry: .paper(paper), facts: facts)
        XCTAssertEqual(item.firstAuthor, "Vaswani et al.")
        XCTAssertEqual(LibraryTableColumn.progress.spoken(item, now: now), "60 percent read", "A ready paper shows how far it is read")
        XCTAssertEqual(LibraryTableColumn.opened.spoken(item, now: now), "Not opened")
        XCTAssertEqual(LibraryTableColumn.added.spoken(item, now: now), "Added today")
        XCTAssertEqual(LibraryTableColumn.chats.spoken(item, now: now), "2 chats")
        XCTAssertEqual(LibraryTableColumn.year.spoken(item, now: now), "2017")
        XCTAssertEqual(LibraryTableColumn.tags.spoken(item, now: now), "Tags: Language, Machine learning")
        XCTAssertEqual(LibraryTableColumn.pages.spoken(item, now: now), "15 pages")
        XCTAssertEqual(LibraryTableColumn.source.spoken(item, now: now), "arXiv 1706.03762")

        let problem = LibraryRowFacts(id: "paper/y", title: "Note", paper: paper, authors: nil, year: nil, tags: [], added: nil,
            opened: nil, progress: 0.3, chats: 0, pages: nil, status: .problem("Not converted"), needsCredits: false)
        XCTAssertEqual(LibraryTableColumn.progress.spoken(LibraryTableItem(entry: .paper(paper), facts: problem), now: now), "Not converted",
                       "A problem takes the place of progress")
        XCTAssertEqual(LibraryTableColumn.chats.spoken(LibraryTableItem(entry: .paper(paper), facts: problem), now: now), "0 chats", "Zero is explicit (build 69 feedback)")

        XCTAssertEqual(LibraryFormat.firstAuthor(["Priya Nair"]), "Priya Nair", "One author keeps the full name")
        XCTAssertEqual(LibraryFormat.firstAuthor(["Ludwig van Beethoven", "X Y"]), "van Beethoven et al.")
        XCTAssertNil(LibraryFormat.firstAuthor([" ", ""]))
        let sample = Paper(id: UUID(), title: "T", authors: "Gradstep · offline sample", year: nil, abstract: "", keywords: [],
                           fileURL: nil, artifactID: nil)
        XCTAssertEqual(LibraryFormat.firstAuthor(for: sample), "Gradstep · offline sample", "Joined byline when names are unknown")
        XCTAssertEqual(LibraryImportStep.downloading.tableTitle, "Downloading", "One word beside the spinner")
    }

    // MARK: Tags, source

    private func paper(_ title: String, keywords: [String] = [], tags: [String] = [], archived: Bool = false,
                       sourceID: String? = nil, url: String? = nil, pages: Int? = nil) -> Paper {
        var paper = Paper(id: UUID(), title: title, authors: "", year: nil, abstract: "", keywords: keywords, fileURL: nil, artifactID: nil)
        paper.tags = tags; paper.archived = archived; paper.sourceID = sourceID; paper.sourceURL = url; paper.pageCount = pages
        return paper
    }

    /// Build 78 ("No Gradstep keywords", Evolving Semantic Indexes for Generative Retrieval): a paper whose title and
    /// abstract give nothing specific and whose catalog tags are missing or generic shows its narrower arXiv subject.
    func testAPaperWithNothingSpecificShowsItsNarrowerSubject() {
        var shown = paper("Evolving Semantic Indexes for Generative Retrieval", keywords: ["cs.IR", "cs.LG"], tags: ["Large language models"])
        XCTAssertEqual(LibraryTags.tags(for: shown), ["Information retrieval"])
        shown = paper("Evolving Semantic Indexes for Generative Retrieval", keywords: ["cs.IR", "cs.LG"])
        XCTAssertEqual(LibraryTags.tags(for: shown), ["Information retrieval"], "before its catalog tags arrive")
        XCTAssertEqual(LibraryTags.tags(for: paper("A", keywords: ["cs.LG", "cs.CL", "cs.AI", "cs.CV"])), [], "never the broad subjects")
        shown.tagsCustomized = true
        XCTAssertEqual(LibraryTags.tags(for: shown), [], "a list the reader cleared stays empty")
    }

    func testTagsKeepSpecificKeywordsWithoutBroadCategoryFallback() {
        XCTAssertEqual(LibraryTags.tags(for: paper("A", keywords: ["cs.LG", "cs.CL", "stat.ML", "cs.LG"])),
                       [], "Broad arXiv subject classes are not discriminative paper keywords (build 70 feedback)")
        XCTAssertEqual(LibraryTags.tags(for: paper("B", keywords: ["cs.LG"], tags: ["Alignment", " alignment ", "", "RLHF"])),
                       ["Alignment", "RLHF"], "Own tags win; trimmed, blank and repeated ones dropped")
        XCTAssertEqual(LibraryTags.tags(for: paper("C")), [])
        XCTAssertEqual(LibraryTags.counts([["Language", "Machine learning"], ["Machine learning"], ["Vision", "Language"], ["Machine learning"]])
            .map { "\($0.tag) \($0.count)" }, ["Machine learning 3", "Language 2", "Vision 1"], "Most used first, then A to Z")
    }

    func testSourceIsTheArxivIdentifierOrTheWebsite() {
        XCTAssertEqual(LibrarySourceLabel.label(sourceID: "1706.03762", url: "https://arxiv.org/abs/1706.03762v7"), "1706.03762")
        XCTAssertEqual(LibrarySourceLabel.spoken(sourceID: "1706.03762", url: nil), "arXiv 1706.03762")
        XCTAssertEqual(LibrarySourceLabel.label(sourceID: "openalex:W2741809807", url: "https://www.nature.com/articles/x.pdf"), "nature.com")
        XCTAssertEqual(LibrarySourceLabel.spoken(sourceID: "openalex:W2741809807", url: "https://www.nature.com/articles/x.pdf"), "From nature.com")
        XCTAssertEqual(LibrarySourceLabel.label(sourceID: "openalex:W2741809807", url: "https://openalex.org/works/W2741809807"), "Open access")
        XCTAssertNil(LibrarySourceLabel.label(sourceID: nil, url: nil), "The sample has no source")
    }

    // MARK: Filters

    func testQuickFiltersByReadingStateArchiveAndImportPhase() {
        let now = Date()
        func paper(_ filter: LibraryFilter, archived: Bool = false, opened: Date? = nil, progress: Double? = nil) -> Bool {
            filter.includesPaper(archived: archived, opened: opened, progress: progress)
        }
        XCTAssertTrue(paper(.all)); XCTAssertFalse(paper(.all, archived: true), "All leaves archived papers out")
        XCTAssertTrue(paper(.archived, archived: true)); XCTAssertFalse(paper(.archived))
        XCTAssertTrue(paper(.unread)); XCTAssertFalse(paper(.unread, opened: now)); XCTAssertFalse(paper(.unread, progress: 0.1))
        XCTAssertFalse(paper(.unread, archived: true), "Archived papers stay under Archived")
        XCTAssertTrue(paper(.reading, opened: now)); XCTAssertTrue(paper(.reading, progress: 0.4))
        XCTAssertFalse(paper(.reading, opened: now, progress: 1), "Finished isn't in progress")
        XCTAssertTrue(paper(.reading, opened: now, progress: 0.996), "99% is still being read")
        XCTAssertFalse(paper(.reading)); XCTAssertFalse(paper(.failed, opened: now))
        XCTAssertTrue(LibraryFilter.all.includesImport(.acquiring))
        XCTAssertTrue(LibraryFilter.failed.includesImport(.failed)); XCTAssertTrue(LibraryFilter.failed.includesImport(.membershipConflict))
        XCTAssertFalse(LibraryFilter.failed.includesImport(.acquiring)); XCTAssertFalse(LibraryFilter.unread.includesImport(.failed))
        XCTAssertTrue(LibraryFilter.all.includesQueued); XCTAssertFalse(LibraryFilter.failed.includesQueued)
    }

    func testFilterRowOffersOnlyFiltersThatNarrowTheList() {
        var summary = LibraryFilterSummary(counts: [.all: 1, .unread: 1])
        XCTAssertEqual(summary.chips(selected: .all, tagSelected: false), [], "A new library (one unread paper): no filter row")
        summary = LibraryFilterSummary(counts: [.all: 8, .unread: 3, .reading: 4, .failed: 1], tags: [("Language", 4), ("Vision", 1)])
        XCTAssertEqual(summary.chips(selected: .all, tagSelected: false), [.all, .unread, .reading, .failed])
        XCTAssertTrue(summary.showsTags(tagSelected: false))
        summary = LibraryFilterSummary(counts: [.all: 5, .unread: 5, .archived: 2], tags: [("Language", 5)])
        XCTAssertEqual(summary.chips(selected: .all, tagSelected: false), [.all, .archived], "Unread equals All here; Archived is apart")
        XCTAssertFalse(summary.showsTags(tagSelected: false), "One tag is nothing to choose between")
        summary = LibraryFilterSummary(counts: [.all: 5, .unread: 5])
        XCTAssertEqual(summary.chips(selected: .failed, tagSelected: false), [.all, .failed], "The chosen filter stays, even when empty")
        XCTAssertEqual(summary.chips(selected: .all, tagSelected: true), [.all], "A chosen tag keeps the row")
    }

    func testFiltersAndTagsNarrowTheLibraryAndItsSearch() async throws {
        let model = ReaderModel(configuration: nil)
        let now = Date()
        var unread = paper("Unread attention", keywords: ["cs.CL"]), reading = paper("Half-read vision", keywords: ["cs.CV"])
        unread.isSample = true   // opens without an account (below)
        let finished = paper("Finished optimisation", keywords: ["math.OC"]), archived = paper("Old archived", keywords: ["cs.CL"], archived: true)
        let tagged = paper("Own tags", keywords: ["cs.LG"], tags: ["Alignment"])
        let failed = try importRecord(phase: "failed", error: "download_failed", categories: ["cs.CL"])
        let running = try importRecord(phase: "acquiring", progress: "converting")
        model.installLibraryMetadataFixture(papers: [unread, reading, finished, archived, tagged], imports: [failed, running], sequences: [:],
            activity: [reading.id: .init(openedAt: now, progress: 0.4), finished.id: .init(openedAt: now, progress: 1)], offline: [:])
        func rows() async -> Set<String> {
            await model.waitForLibrarySearch()
            return Set(model.libraryRows.map { $0.title })
        }
        let importTitle = "Imported language paper", runningTitle = "arXiv 2006.11239"
        let all: Set<String> = [unread.title, reading.title, finished.title, tagged.title, importTitle, runningTitle]
        var shown = await rows()
        XCTAssertEqual(shown, all, "All: everything but archived papers")
        model.libraryFilter = .unread
        shown = await rows(); XCTAssertEqual(shown, [unread.title, tagged.title])
        model.libraryFilter = .reading
        shown = await rows(); XCTAssertEqual(shown, [reading.title])
        model.libraryFilter = .failed
        shown = await rows(); XCTAssertEqual(shown, [importTitle])
        model.libraryFilter = .archived
        shown = await rows(); XCTAssertEqual(shown, [archived.title])

        model.libraryFilter = .all; model.libraryTagFilter = "Natural language processing"
        shown = await rows(); XCTAssertEqual(shown, [], "Broad categories are not paper keywords (build 70 feedback)")
        model.libraryTagFilter = "Alignment"
        shown = await rows(); XCTAssertEqual(shown, [tagged.title], "The paper's own tags")
        model.libraryTagFilter = nil; model.libraryQuery = "language"
        shown = await rows(); XCTAssertEqual(shown, [importTitle], "The title matches language; a broad subject class does not add a keyword match")
        model.libraryQuery = ""

        let summary = model.libraryFilterSummary()
        XCTAssertEqual(summary.count(.failed), 1); XCTAssertEqual(summary.count(.archived), 1); XCTAssertEqual(summary.count(.reading), 1)
        XCTAssertEqual(summary.tags.first?.tag, "Alignment", "Specific own keywords remain available without category placeholders")
        XCTAssertFalse(summary.tags.contains { $0.tag == "Computer vision" && $0.count != 1 })

        // Reading a paper moves it out of Unread at once.
        model.libraryFilter = .unread
        _ = await rows()
        model.select(unread)
        let afterOpening = await rows()
        XCTAssertFalse(afterOpening.contains(unread.title), "Opened papers leave Unread")
    }

    /// Owner, TestFlight 92: "Is the check mark right in the middle of the column?" The Device column is centred, so its
    /// header and every glyph (check, cloud, warning, each in the same box) share one centre at every width; numbers keep
    /// to the trailing edge and text to the leading one.
    func testDeviceGlyphsAreCentredUnderTheirHeader() {
        XCTAssertEqual(LibraryTableColumn.device.column.alignment, .center)
        XCTAssertEqual(LibraryTableColumn.chats.column.alignment, .trailing)
        XCTAssertEqual(LibraryTableColumn.pages.column.alignment, .trailing)
        for column in LibraryTableColumn.allCases where ![.device, .chats, .pages].contains(column) {
            XCTAssertEqual(column.column.alignment, .leading, column.rawValue)
        }
        XCTAssertLessThanOrEqual(LibraryTableCell.deviceGlyphBox, LibraryTableColumn.device.width, "every glyph's box fits the column")
    }

    /// Filter + related (owner, TestFlight 92): the related rows the rule admits follow the tagged rows, each group in the
    /// chosen order, with their reasons; the other candidates stay out, and without the request none show.
    func testRelatedRowsFollowTheTaggedOnesWithTheirReasons() async throws {
        func unit(_ similarity: Float, axis: Int) -> [Float] {
            var v = [Float](repeating: 0, count: 384); v[0] = similarity; v[axis] = (1 - similarity * similarity).squareRoot(); return v
        }
        func candidate(_ id: String, _ title: String, sequence: Int64, group: Int) -> LibrarySearchCandidate {
            LibrarySearchCandidate(id: id, title: title, fields: [title], recentSequence: sequence, position: Int(sequence), group: group)
        }
        let rows = [candidate("t1", "Zeta tagged", sequence: 1, group: 0), candidate("t2", "Alpha tagged", sequence: 2, group: 0),
                    candidate("close", "Beta close", sequence: 5, group: 1),
                    candidate("words", "Gamma: speculative drafting at scale", sequence: 4, group: 1),
                    candidate("far", "Aardvark unrelated", sequence: 3, group: 1)]
        let request = LibraryRelatedRequest(tag: "Speculative drafting",
            tagged: [.init(id: "t1", title: "Zeta tagged", abstract: "", vector: unit(1, axis: 1)),
                     .init(id: "t2", title: "Alpha tagged", abstract: "", vector: unit(0.95, axis: 2))],
            candidates: [.init(id: "close", title: "Beta close", abstract: "", vector: unit(0.97, axis: 3)),
                         .init(id: "words", title: "Gamma: speculative drafting at scale", abstract: "", vector: nil),
                         .init(id: "far", title: "Aardvark unrelated", abstract: "", vector: unit(0.5, axis: 4))],
            termsDigest: nil, terms: nil)
        func run(_ sort: LibrarySearchSort) async throws -> LibrarySearchOutput {
            let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: "", sort: sort)
            return try await LibrarySearchEngine.run(LibrarySearchInput(ticket: .init(key: key), candidates: rows, related: request))
        }
        let byTitle = try await run(.title)
        XCTAssertEqual(byTitle.rowIDs, ["t2", "t1", "close", "words"], "tagged first, then related, each A to Z; the far paper is left out")
        XCTAssertEqual(byTitle.related["close"]?.text, "Related to 2 tagged papers")
        XCTAssertEqual(byTitle.related["words"]?.text, "Mentions “speculative drafting”")
        XCTAssertNil(byTitle.related["far"])
        let recent = try await run(.recent), reversed = try await run(LibrarySearchSort(field: .title, ascending: false))
        XCTAssertEqual(recent.rowIDs, ["t2", "t1", "close", "words"], "newest first within each group")
        XCTAssertEqual(reversed.rowIDs, ["t1", "t2", "words", "close"], "reversing the order never mixes the groups")
        let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: "", sort: .recent)
        XCTAssertEqual(try LibrarySearchEngine.search(.init(ticket: .init(key: key), candidates: rows)), ["t2", "t1"], "plain Filter")
    }

    /// The model's Filter / Filter + related: the tagged papers, then those using the tag's words (no fingerprints in a unit
    /// test), each with its reason; clearing the tag clears both.
    func testFilterPlusRelatedThroughTheLibrary() async throws {
        let model = ReaderModel(configuration: nil)
        var tagged = paper("Trees of drafts", tags: ["Speculative drafting"]); tagged.tagsCustomized = true
        let mentions = paper("Two-stage speculative drafting for long outputs"), unrelated = paper("Graph kernels for molecules")
        model.installLibraryMetadataFixture(papers: [tagged, mentions, unrelated], imports: [], sequences: [:], activity: [:], offline: [:])
        func rows() async -> [String] { await model.waitForLibrarySearch(); return model.libraryRows.map(\.title) }
        model.filterLibrary(byTag: "Speculative drafting", related: false)
        var shown = await rows()
        XCTAssertEqual(shown, [tagged.title])
        XCTAssertTrue(model.libraryRelated.isEmpty)
        model.filterLibrary(byTag: "Speculative drafting", related: true)
        shown = await rows()
        XCTAssertEqual(shown, [tagged.title, mentions.title], "the tagged paper, then one that uses the tag's words")
        XCTAssertEqual(model.libraryRelated[LibraryListEntry.paper(mentions).id]?.text, "Mentions “speculative drafting”")
        model.libraryTagFilter = nil
        XCTAssertFalse(model.libraryTagIncludesRelated, "Clearing the tag clears its related papers")
        shown = await rows()
        XCTAssertEqual(Set(shown), [tagged.title, mentions.title, unrelated.title])
        XCTAssertTrue(model.libraryRelated.isEmpty)
        // A keyword's choices in the paper: the same, from anywhere.
        model.showLibraryPapers(taggedWith: "Speculative drafting", related: true)
        XCTAssertEqual(model.libraryTagFilter, "Speculative drafting"); XCTAssertTrue(model.libraryTagIncludesRelated)
        shown = await rows()
        XCTAssertEqual(shown, [tagged.title, mentions.title])
    }

    func testNewOrdersSortByTagPagesAndSource() throws {
        func candidate(_ id: String, sequence: Int64, tag: String?, pages: Int?, source: String?) -> LibrarySearchCandidate {
            LibrarySearchCandidate(id: id, title: id, fields: [id], recentSequence: sequence, position: Int(sequence),
                                   keys: LibrarySortKeys(tag: tag, pages: pages, source: source))
        }
        let rows = [candidate("a", sequence: 4, tag: "Vision", pages: 12, source: "2106.09685"),
                    candidate("b", sequence: 3, tag: "Language", pages: 27, source: "openalex.org"),
                    candidate("c", sequence: 2, tag: nil, pages: nil, source: nil),
                    candidate("d", sequence: 1, tag: "Language", pages: 12, source: "1706.03762")]
        func order(_ field: LibrarySearchSort.Field, ascending: Bool? = nil) throws -> [String] {
            let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: "", sort: .init(field: field, ascending: ascending))
            return try LibrarySearchEngine.search(.init(ticket: .init(key: key), candidates: rows))
        }
        XCTAssertEqual(try order(.tags), ["b", "d", "a", "c"], "A to Z by first tag, ties in recent order, untagged last")
        XCTAssertEqual(try order(.tags, ascending: false), ["a", "b", "d", "c"])
        XCTAssertEqual(try order(.pages), ["b", "a", "d", "c"], "Longest first; unknown last")
        XCTAssertEqual(try order(.source), ["d", "a", "b", "c"], "Identifiers in order, websites after")
        XCTAssertEqual(LibrarySearchSort.Field.allCases.filter(\.isTableOnly), [.authors, .tags, .pages, .source])
    }

    // MARK: Stopped imports

    private func importRecord(phase: String, progress: String? = nil, error: String? = nil, retryable: Bool? = nil,
                              categories: [String] = []) throws -> LibraryImportRecord {
        var value: [String: Any] = ["id": UUID().wire, "created_seq": 1, "state_seq": 1, "intent_revision": 1, "visible": true,
            "phase": phase, "source": "arxiv", "source_id": "2006.11239", "source_url": "https://arxiv.org/abs/2006.11239",
            "retryable": retryable ?? (phase == "failed")]
        if !categories.isEmpty {
            value.merge(["source_url": "https://arxiv.org/abs/2006.11239v1", "source_revision": 1, "metadata_id": UUID().wire,
                         "version_id": UUID().wire, "metadata_recorded_at": "2026-10-01T09:00:00Z",
                         "metadata": ["title": "Imported language paper", "authors": ["A B"], "categories": categories] as [String: Any]]) { $1 }
        }
        if let progress { value["progress"] = progress }
        if let error { value["error_code"] = error }
        return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testEveryStoppedImportOffersAnAction() throws {
        func action(_ phase: String, _ error: String?, retryable: Bool? = nil) throws -> LibraryImportAction? {
            LibraryImportAction.available(for: try importRecord(phase: phase, error: error, retryable: retryable), retrying: false)
        }
        XCTAssertEqual(try action("failed", "download_failed"), .retry)
        XCTAssertEqual(try action("failed", "rate_limited"), .retry)
        XCTAssertEqual(try action("failed", "insufficient_credits", retryable: false), .getCredits)
        XCTAssertEqual(try action("failed", "too_large", retryable: false), .remove, "Nothing to retry: it can at least be removed")
        XCTAssertEqual(try action("failed", "pdf_invalid", retryable: false), .remove)
        XCTAssertNil(try action("acquiring", nil), "Running imports have Cancel in their menu, nothing inline")
        XCTAssertNil(LibraryImportAction.available(for: try importRecord(phase: "failed", error: "download_failed"), retrying: true),
                     "No Retry while one is on its way")
        XCTAssertEqual(try importRecord(phase: "failed", error: "download_failed").libraryShortStatus, "Download failed", "Plain words")
        XCTAssertEqual(try importRecord(phase: "failed", error: "metadata_unavailable").retryStep, .finding, "Details unknown: find it again")
        XCTAssertEqual(try importRecord(phase: "failed", error: "download_failed", categories: ["cs.LG"]).retryStep, .downloading)
    }

    func testRetryInTheFixtureShowsDownloadingAtOnceAndRemoveTakesTheRowAway() async throws {
        let model = ReaderModel(configuration: nil)
        let failed = try importRecord(phase: "failed", error: "download_failed", categories: ["cs.CL"])
        let tooLarge = try importRecord(phase: "failed", error: "too_large", retryable: false)
        model.installLibraryMetadataFixture(papers: [], imports: [failed, tooLarge], sequences: [:], activity: [:], offline: [:])
        XCTAssertTrue(model.canChangeImports, "Fixture runs act locally")
        let item = LibraryTableItem(entry: .pending(failed), facts: model.libraryFacts(for: .pending(failed)))
        XCTAssertEqual(item.facts.importAction, .retry)
        XCTAssertEqual(LibraryTableColumn.progress.spoken(item), "Couldn’t download this paper", "VoiceOver reads the full status")

        await model.changeImport(failed, retry: true)
        let retried = LibraryTableItem(entry: .pending(failed), facts: model.libraryFacts(for: .pending(failed)))
        XCTAssertEqual(model.libraryStatus(for: .pending(failed)), .active("Downloading…"))
        XCTAssertEqual(retried.facts.step, .downloading)
        XCTAssertNil(retried.facts.importAction)
        XCTAssertEqual(LibraryTableColumn.progress.spoken(retried), LibraryImportStep.downloading.title)

        await model.changeImport(tooLarge, retry: true)
        XCTAssertFalse(model.isRetrying(tooLarge), "Not retryable: Retry does nothing")
        await model.changeImport(tooLarge, retry: false)
        await model.waitForLibrarySearch()
        XCTAssertFalse(model.libraryRows.contains { $0.id == "import/\(tooLarge.id.wire)" }, "Removed")
    }

    // MARK: Feed

    private func results(_ rows: [(id: String, title: String, year: Int?, categories: [String])]) throws -> [DiscoveryResult] {
        let json = rows.map { row in
            ["source_id": row.id, "revision": 1, "title": row.title, "authors": ["A B"], "year": row.year as Any,
             "abstract": NSNull(), "categories": row.categories] as [String: Any]
        }
        return try JSONDecoder().decode([DiscoveryResult].self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testFeedPublishedComesFromTheArxivIdentifier() throws {
        XCTAssertEqual(FeedFormat.arxivMonth("2610.01234")?.year, 2026)
        XCTAssertEqual(FeedFormat.arxivMonth("2610.01234v2")?.month, 10)
        XCTAssertEqual(FeedFormat.arxivMonth("2610.01234v2")?.number, 1234)
        XCTAssertEqual(FeedFormat.arxivMonth("0704.0001")?.year, 2007)
        XCTAssertEqual(FeedFormat.arxivMonth("hep-th/9901001v1")?.year, 1999)
        XCTAssertEqual(FeedFormat.arxivMonth("solv-int/9901001")?.month, 1, "An archive name with a v")
        XCTAssertNil(FeedFormat.arxivMonth("2613.00001"), "No month 13")
        XCTAssertNil(FeedFormat.arxivMonth("W2741809807"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let rows = try results([("2610.01234", "A", 2026, ["cs.LG"]), ("2609.11890", "B", 2026, [])])
        XCTAssertEqual(FeedFormat.published(rows[0], calendar: calendar), "Oct 2026")
        XCTAssertEqual(FeedFormat.spokenPublished(rows[1], calendar: calendar), "Published September 2026")
        XCTAssertEqual(FeedFormat.topic(rows[0]), "Machine learning")
        XCTAssertNil(FeedFormat.topic(rows[1]))
    }

    func testFeedSortsByHeaderKeepingTheServerOrderForTies() throws {
        let rows = try results([
            ("2610.02287", "test-time training", 2026, ["cs.CL"]),
            ("2610.01234", "Sparse experts", 2026, ["cs.LG", "cs.CL"]),
            ("2610.03011", "Diffusion policies", 2026, ["cs.RO"]),
            ("2609.11890", "Calibrated uncertainty", 2026, []),
            ("2610.01235", "Another sparse paper", 2026, ["cs.LG"]),
        ])
        func order(_ key: FeedSortKey, ascending: Bool) -> [String] {
            FeedFormat.ordered(rows, by: PaperTableSort(key: key, ascending: ascending)).map(\.sourceID)
        }
        XCTAssertEqual(FeedTableColumn.defaultSort, PaperTableSort(key: .published, ascending: false), "Newest first by default")
        XCTAssertEqual(order(.published, ascending: false), ["2610.03011", "2610.02287", "2610.01235", "2610.01234", "2609.11890"])
        XCTAssertEqual(order(.published, ascending: true), ["2609.11890", "2610.01234", "2610.01235", "2610.02287", "2610.03011"])
        XCTAssertEqual(order(.title, ascending: true), ["2610.01235", "2609.11890", "2610.03011", "2610.01234", "2610.02287"],
                       "Case doesn't matter")
        XCTAssertEqual(order(.topic, ascending: true), ["2610.01234", "2610.01235", "2610.02287", "2610.03011", "2609.11890"],
                       "Machine learning (server order for ties), Natural language processing, Robotics; no topic last")
        XCTAssertEqual(order(.topic, ascending: false), ["2610.03011", "2610.02287", "2610.01234", "2610.01235", "2609.11890"],
                       "No topic stays last when reversed")
    }
}
