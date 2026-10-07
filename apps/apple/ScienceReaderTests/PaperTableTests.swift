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

    private func libraryColumns(_ width: CGFloat, scale: CGFloat = 1, topics: Bool = true) -> [String] {
        PaperTableLayout.visibleColumns(LibraryTableColumn.all(showTopics: topics), width: width, scale: scale).map(\.id)
    }

    private func feedColumns(_ width: CGFloat, scale: CGFloat = 1) -> [String] {
        PaperTableLayout.visibleColumns(FeedTableColumn.all, width: width, scale: scale).map(\.id)
    }

    func testLibraryColumnsFollowTheWidth() {
        let phone = ["year", "progress"]
        XCTAssertEqual(libraryColumns(Width.phoneSmall), phone, "Phone portrait: title, year and progress")
        XCTAssertEqual(libraryColumns(Width.phone), phone)
        XCTAssertEqual(libraryColumns(Width.phoneMax), phone)
        let wide = ["year", "added", "opened", "chats", "progress"]
        XCTAssertEqual(libraryColumns(Width.phoneLandscape), wide, "Phone landscape adds the dates and chats")
        XCTAssertEqual(libraryColumns(Width.padPortrait), wide, "iPad portrait shows the table too (no fallback to rows)")
        XCTAssertEqual(libraryColumns(Width.padLandscape), ["year", "topics", "added", "opened", "chats", "progress"])
        XCTAssertEqual(libraryColumns(Width.padLandscape, topics: false), wide, "Show › Topics off hides the column")
        XCTAssertEqual(libraryColumns(Width.browseColumn), ["progress"], "The iPad Browse column keeps progress before year")
        XCTAssertEqual(libraryColumns(Width.phone, scale: 1.35), ["progress"], "Larger text needs more room per column")
        XCTAssertEqual(libraryColumns(0), [], "Before the first measurement, the title alone")
    }

    func testFeedColumnsFollowTheWidth() {
        XCTAssertEqual(feedColumns(Width.phoneSmall), ["published", "add"], "Phone portrait: title, published and Add")
        XCTAssertEqual(feedColumns(Width.phone), ["published", "add"])
        XCTAssertEqual(feedColumns(Width.phoneLandscape), ["topic", "published", "add"])
        XCTAssertEqual(feedColumns(Width.padPortrait), ["topic", "published", "add"])
    }

    func testTitleKeepsItsShareAndWideningOnlyAddsColumns() {
        checkFitAndGrowth(LibraryTableColumn.all(showTopics: true))
        checkFitAndGrowth(FeedTableColumn.all)
    }

    private func checkFitAndGrowth<Key>(_ columns: [PaperTableColumn<Key>], file: StaticString = #filePath, line: UInt = #line) {
        var previous = Set<String>()
        for width in stride(from: CGFloat(100), through: 1600, by: 7) {
            for scale in [CGFloat(1), 1.2, 1.5] {
                let visible = PaperTableLayout.visibleColumns(columns, width: width, scale: scale)
                guard !visible.isEmpty else { continue }
                let columnsWidth = visible.reduce(0) { $0 + PaperTableLayout.spacing + $1.width * scale }
                XCTAssertGreaterThanOrEqual(width - columnsWidth, PaperTableLayout.titleWidth(in: width, scale: scale),
                                            "The title keeps its share and nothing overflows at \(width) × \(scale)", file: file, line: line)
            }
            let ids = Set(PaperTableLayout.visibleColumns(columns, width: width).map(\.id))
            XCTAssertTrue(previous.isSubset(of: ids), "Widening to \(width) dropped \(previous.subtracting(ids))", file: file, line: line)
            previous = ids
        }
    }

    func testHeaderTapsSortThenReverse() {
        let columns = Dictionary(uniqueKeysWithValues: (LibraryTableColumn.all(showTopics: true) + [LibraryTableColumn.title]).map { ($0.id, $0) })
        var sort = PaperTableSort(key: LibrarySearchSort.Field.recent, ascending: false)
        sort = sort.tapping(columns["year"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .year, ascending: false), "Year starts newest first")
        sort = sort.tapping(columns["year"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .year, ascending: true), "Tapping again reverses")
        sort = sort.tapping(columns["title"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .title, ascending: true), "Title starts A to Z")
        sort = sort.tapping(columns["progress"]!)
        XCTAssertEqual(sort, PaperTableSort(key: .progress, ascending: false), "Most read first")
        XCTAssertEqual(sort.tapping(columns["topics"]!), sort, "A column without a sort leaves the order alone")
        // Each sortable header starts in the direction the Sort menu uses for that field.
        for column in columns.values {
            guard let field = column.sortKey else { continue }
            XCTAssertEqual(column.ascendingFirst, field.defaultAscending, column.id)
        }
        XCTAssertEqual(Set(columns.values.compactMap(\.sortKey)), Set(LibrarySearchSort.Field.allCases).subtracting([.authors]),
                       "Every sort but Authors has a header (authors stay in the Sort menu)")
    }

    // MARK: Library values

    func testLibraryValuesAndSpokenRow() {
        let now = Date(timeIntervalSince1970: 1_791_201_600)
        var paper = Paper(id: UUID(), title: "Attention Is All You Need", authors: "", year: 2017, abstract: "", keywords: [],
                          fileURL: nil, artifactID: nil)
        paper.authorNames = ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"]
        let facts = LibraryRowFacts(id: "paper/x", title: paper.title, paper: paper, authors: "Vaswani, Shazeer +1", year: 2017,
            topics: ["Language"], added: now, opened: nil, progress: 0.6, chats: 2, pages: 15, status: .info("Not downloaded"),
            needsCredits: false)
        let item = LibraryTableItem(entry: .paper(paper), facts: facts)
        XCTAssertEqual(item.firstAuthor, "Vaswani et al.")
        XCTAssertEqual(LibraryTableColumn.progress.spoken(item, now: now), "60 percent read", "A ready paper shows how far it is read")
        XCTAssertEqual(LibraryTableColumn.opened.spoken(item, now: now), "Not opened")
        XCTAssertEqual(LibraryTableColumn.added.spoken(item, now: now), "Added today")
        XCTAssertEqual(LibraryTableColumn.chats.spoken(item, now: now), "2 chats")
        XCTAssertEqual(LibraryTableColumn.year.spoken(item, now: now), "2017")

        let problem = LibraryRowFacts(id: "paper/y", title: "Note", paper: paper, authors: nil, year: nil, topics: [], added: nil,
            opened: nil, progress: 0.3, chats: 0, pages: nil, status: .problem("Not converted"), needsCredits: false)
        XCTAssertEqual(LibraryTableColumn.progress.spoken(LibraryTableItem(entry: .paper(paper), facts: problem), now: now), "Not converted",
                       "A problem takes the place of progress")
        XCTAssertNil(LibraryTableColumn.chats.spoken(LibraryTableItem(entry: .paper(paper), facts: problem), now: now))

        XCTAssertEqual(LibraryFormat.firstAuthor(["Priya Nair"]), "Priya Nair", "One author keeps the full name")
        XCTAssertEqual(LibraryFormat.firstAuthor(["Ludwig van Beethoven", "X Y"]), "van Beethoven et al.")
        XCTAssertNil(LibraryFormat.firstAuthor([" ", ""]))
        let sample = Paper(id: UUID(), title: "T", authors: "Gradstep · offline sample", year: nil, abstract: "", keywords: [],
                           fileURL: nil, artifactID: nil)
        XCTAssertEqual(LibraryFormat.firstAuthor(for: sample), "Gradstep · offline sample", "Joined byline when names are unknown")
        XCTAssertEqual(LibraryImportStep.downloading.tableTitle, "Downloading", "One word beside the spinner")
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
        XCTAssertEqual(order(.topic, ascending: true), ["2610.02287", "2610.01234", "2610.01235", "2610.03011", "2609.11890"],
                       "Language, Machine learning (server order for ties), Robotics; no topic last")
        XCTAssertEqual(order(.topic, ascending: false), ["2610.03011", "2610.01234", "2610.01235", "2610.02287", "2609.11890"],
                       "No topic stays last when reversed")
    }
}
