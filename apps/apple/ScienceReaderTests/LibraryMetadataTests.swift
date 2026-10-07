import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Library table / detailed-row presentation (owner decision 2026-10-05): formatting helpers,
/// the extended sort orders, and this device's reading activity.
@MainActor
final class LibraryMetadataTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
    /// Monday 5 October 2026, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_791_201_600)
    private let day: TimeInterval = 86_400

    func testShortAuthors() {
        XCTAssertNil(LibraryFormat.shortAuthors([]))
        XCTAssertNil(LibraryFormat.shortAuthors(["  ", ""]))
        XCTAssertEqual(LibraryFormat.shortAuthors(["Ashish Vaswani"]), "Ashish Vaswani", "One author keeps the full name")
        XCTAssertEqual(LibraryFormat.shortAuthors(["Diederik P. Kingma", "Jimmy Ba"]), "Kingma, Ba")
        XCTAssertEqual(LibraryFormat.shortAuthors(["Ashish Vaswani", "Noam Shazeer", "Niki Parmar", "Jakob Uszkoreit",
                                                   "Llion Jones", "Aidan N. Gomez", "Łukasz Kaiser", "Illia Polosukhin"]),
                       "Vaswani, Shazeer +6")
        XCTAssertEqual(LibraryFormat.shortAuthors(["A B", "C D", "E F"]), "B, D +1")
        XCTAssertEqual(LibraryFormat.familyName("Vaswani, Ashish"), "Vaswani")
        XCTAssertEqual(LibraryFormat.familyName("Ludwig van Beethoven"), "van Beethoven")
        XCTAssertEqual(LibraryFormat.familyName("Martin Luther King Jr."), "King")
        XCTAssertEqual(LibraryFormat.familyName("Martin Luther King, Jr."), "King")
        XCTAssertEqual(LibraryFormat.familyName("Plato"), "Plato")
        XCTAssertEqual(LibraryFormat.familyName("Zeyuan Allen-Zhu"), "Allen-Zhu")

        var paper = Paper(id: UUID(), title: "T", authors: "Gradstep · offline sample", year: nil, abstract: "",
                          keywords: [], fileURL: nil, artifactID: nil)
        XCTAssertEqual(LibraryFormat.shortAuthors(for: paper), "Gradstep · offline sample", "Joined byline when names are unknown")
        paper.authorNames = ["Kaiming He", "Xiangyu Zhang", "Shaoqing Ren", "Jian Sun"]
        XCTAssertEqual(LibraryFormat.shortAuthors(for: paper), "He, Zhang +2")
    }

    func testRelativeDays() {
        let format = { (date: Date) in LibraryFormat.relativeDay(date, now: self.now, calendar: self.calendar) }
        XCTAssertEqual(format(now - 3_600), "Today")
        XCTAssertEqual(format(now + 3 * day), "Today", "A clock running ahead never shows a future date")
        XCTAssertEqual(format(now - day), "Yesterday")
        XCTAssertEqual(format(now - 2 * day), "Sat")
        XCTAssertEqual(format(now - 6 * day), "Tue")
        XCTAssertEqual(format(now - 7 * day), "Sep 28")
        XCTAssertEqual(format(now - 100 * day), "Jun 27")
        XCTAssertEqual(format(now - 280 * day), "Dec 2025", "Earlier years show the month and year")
        XCTAssertEqual(format(now - 372 * day), "Sep 2025")
        XCTAssertEqual(LibraryFormat.relativeDayInSentence(now, now: now, calendar: calendar), "today")
        XCTAssertEqual(LibraryFormat.relativeDayInSentence(now - day, now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(LibraryFormat.relativeDayInSentence(now - 2 * day, now: now, calendar: calendar), "Sat")
    }

    func testTopicNames() {
        XCTAssertEqual(ArxivTopics.names(for: ["cs.CL", "cs.LG", "cs.AI"]), ["Language", "Machine learning"], "At most two")
        XCTAssertEqual(ArxivTopics.names(for: ["math.OC"]), ["Optimization"])
        XCTAssertEqual(ArxivTopics.names(for: ["math.ST", "stat.TH", "cs.LG"]), ["Statistics theory", "Machine learning"], "Duplicates collapse")
        XCTAssertEqual(ArxivTopics.name(for: "math.KT"), "Mathematics", "Archive name when the category has none")
        XCTAssertEqual(ArxivTopics.name(for: "hep-th"), "High-energy theory")
        XCTAssertEqual(ArxivTopics.name(for: "attention"), "Attention", "Free-text keywords read as words")
        XCTAssertEqual(ArxivTopics.name(for: "xx.YY"), "xx.YY", "Unknown codes stay as they are")
        XCTAssertTrue(ArxivTopics.names(for: []).isEmpty)
        for (code, name) in ArxivTopics.feedNames { XCTAssertEqual(ArxivTopics.name(for: code), name, "Feed labels are unchanged") }
    }

    func testProgressAndActivityLines() {
        XCTAssertEqual(LibraryFormat.percent(0), 0)
        XCTAssertEqual(LibraryFormat.percent(0.6), 60)
        XCTAssertEqual(LibraryFormat.percent(0.996), 99, "Nearly finished doesn't round up to done")
        XCTAssertEqual(LibraryFormat.percent(1), 100)
        XCTAssertEqual(LibraryFormat.percent(-0.2), 0)
        XCTAssertEqual(LibraryFormat.percent(3), 100)
        XCTAssertEqual(LibraryFormat.percent(.nan), 0)
        XCTAssertEqual(LibraryFormat.chats(1), "1 chat")
        XCTAssertEqual(LibraryFormat.chats(3), "3 chats")

        let paper = Paper(id: UUID(), title: "Attention", authors: "", year: 2017, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        let full = LibraryRowFacts(id: "paper/x", title: "Attention", paper: paper, authors: "Vaswani, Shazeer +6", year: 2017,
            topics: ["Language", "Machine learning"], added: now - 7 * day, opened: now, progress: 0.6, chats: 2, pages: 15,
            status: .none, needsCredits: false)
        XCTAssertEqual(full.summaryLine(showTopics: true), "Vaswani, Shazeer +6 · 2017 · Language, Machine learning")
        XCTAssertEqual(full.summaryLine(showTopics: false), "Vaswani, Shazeer +6 · 2017")
        XCTAssertEqual(full.activityLine(now: now, calendar: calendar), "Added Sep 28 · Opened today · 60% read · 2 chats")
        let sparse = LibraryRowFacts(id: "paper/y", title: "Note", paper: paper, authors: nil, year: nil, topics: [], added: nil,
            opened: nil, progress: nil, chats: 0, pages: nil, status: .none, needsCredits: false)
        XCTAssertEqual(sparse.summaryLine(showTopics: true), "")
        XCTAssertEqual(sparse.activityLine(now: now, calendar: calendar), "Not opened", "Unknown facts are omitted, never blank")
        let pending = LibraryRowFacts(id: "import/z", title: "Pending", paper: nil, authors: "Kaplan, McCandlish +8", year: 2020,
            topics: [], added: nil, opened: nil, progress: nil, chats: 0, pages: nil, status: .active("Converting…"), needsCredits: false)
        XCTAssertEqual(pending.activityLine(now: now, calendar: calendar), "", "Imports have no reading activity")
        XCTAssertEqual(pending.statusText, "Converting…")
        XCTAssertNil(full.statusText, "A ready paper has no status label")
    }

    // MARK: Sorting

    private func candidate(_ id: String, title: String = "T", sequence: Int64, position: Int, year: Int? = nil,
                           authors: String? = nil, opened: Date? = nil, progress: Double? = nil, chats: Int = 0) -> LibrarySearchCandidate {
        LibrarySearchCandidate(id: id, title: title, fields: [title], recentSequence: sequence, position: position,
            keys: LibrarySortKeys(authors: authors, year: year, opened: opened, progress: progress, chats: chats))
    }

    private func order(_ rows: [LibrarySearchCandidate], _ sort: LibrarySearchSort, query: String = "") throws -> [String] {
        let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: query, sort: sort)
        return try LibrarySearchEngine.search(.init(ticket: .init(key: key), candidates: rows))
    }

    func testExtendedSortsKeepMissingValuesLastAndTiesInRecentOrder() throws {
        let rows = [
            candidate("a", title: "Beta", sequence: 4, position: 0, year: 2017, authors: "Vaswani", opened: now - day, progress: 0.6, chats: 2),
            candidate("b", title: "alpha", sequence: 3, position: 1, year: 2023, authors: "Rafailov", opened: now, progress: 0.25, chats: 0),
            candidate("c", title: "Gamma", sequence: 2, position: 2, year: nil, authors: nil, opened: nil, progress: nil, chats: 0),
            candidate("d", title: "Delta", sequence: 1, position: 3, year: 2017, authors: "He", opened: now - 9 * day, progress: 1, chats: 3),
        ]
        XCTAssertEqual(try order(rows, .recent), ["a", "b", "c", "d"])
        XCTAssertEqual(try order(rows, .init(field: .recent, ascending: true)), ["d", "c", "b", "a"])
        XCTAssertEqual(try order(rows, .title), ["b", "a", "d", "c"])
        XCTAssertEqual(try order(rows, .init(field: .title, ascending: false)), ["c", "d", "a", "b"])
        XCTAssertEqual(try order(rows, .init(field: .year)), ["b", "a", "d", "c"], "Newest first; equal years keep recent order; no year last")
        XCTAssertEqual(try order(rows, .init(field: .year, ascending: true)), ["a", "d", "b", "c"], "No year stays last when reversed")
        XCTAssertEqual(try order(rows, .init(field: .authors)), ["d", "b", "a", "c"])
        XCTAssertEqual(try order(rows, .init(field: .opened)), ["b", "a", "d", "c"], "Never opened last")
        XCTAssertEqual(try order(rows, .init(field: .opened, ascending: true)), ["d", "a", "b", "c"])
        XCTAssertEqual(try order(rows, .init(field: .progress)), ["d", "a", "b", "c"])
        XCTAssertEqual(try order(rows, .init(field: .chats)), ["d", "a", "b", "c"], "Zero chats keep recent order")
        XCTAssertEqual(try order(rows, .init(field: .progress), query: "ta"), ["d", "a"], "Searching keeps only matches, in the chosen order")
    }

    func testTableComparatorAgreesWithTheSearchOrder() throws {
        let rows = (0..<12).map { n in
            candidate("paper/\(n)", title: "Paper \(11 - n)", sequence: Int64(n % 5), position: n, year: n % 3 == 0 ? nil : 2010 + n % 4,
                      authors: n % 4 == 0 ? nil : "Author \(n % 3)", opened: n % 2 == 0 ? now - Double(n) * day : nil,
                      progress: n % 3 == 1 ? Double(n) / 12 : nil, chats: n % 4)
        }
        let entries = Dictionary(uniqueKeysWithValues: rows.map { candidate in
            (candidate.id, LibraryTableRow(entry: .paper(Paper(id: UUID(), title: candidate.title, authors: "", year: nil, abstract: "",
                keywords: [], fileURL: nil, artifactID: nil)), candidate: candidate))
        })
        for field in LibrarySearchSort.Field.allCases {
            for ascending in [true, false] {
                let sort = LibrarySearchSort(field: field, ascending: ascending)
                let tableRows = rows.reversed().map { entries[$0.id]! }
                let sorted = tableRows.sorted(using: LibraryTableComparator(sort)).map(\.candidate.id)
                XCTAssertEqual(sorted, try order(rows, sort), "\(field) ascending=\(ascending)")
            }
        }
        XCTAssertEqual(LibraryTableComparator(field: .year).order, .reverse, "Year starts newest first")
        XCTAssertEqual(LibraryTableComparator(field: .title).order, .forward)
        XCTAssertEqual(LibraryTableComparator(field: .progress).sort, LibrarySearchSort(field: .progress))
    }

    // MARK: Model

    func testOpeningReadingAndChatsUpdateActivityAndActivityOrders() async throws {
        let model = ReaderModel(configuration: nil)
        func sample(_ title: String) -> Paper {
            Paper(id: UUID(), title: title, authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: UUID(), isSample: true)
        }
        let first = sample("First"), second = sample("Second")
        model.papers = [first, second]
        await model.waitForLibrarySearch()
        XCTAssertNil(model.readingActivity[second.id])
        XCTAssertEqual(model.libraryFacts(for: .paper(second)).activityLine(), "Not opened")

        model.select(second)
        let opened = try XCTUnwrap(model.readingActivity[second.id]?.openedAt)
        XCTAssertLessThan(abs(opened.timeIntervalSinceNow), 5)
        let location = PaperReadingLocation(blockIndex: 3, blockFraction: 0.2, blockHeight: 120, scrollY: 900, progress: 0.42)
        model.recordReadingLocation(location, key: "first/artifact", documentID: first.id)
        XCTAssertEqual(model.paperLocations["first/artifact"], location, "The position itself is kept as before")
        XCTAssertEqual(model.libraryFacts(for: .paper(first)).progress, 0.42)
        XCTAssertNil(model.libraryFacts(for: .paper(first)).opened, "Progress without an open on this device leaves Opened unknown")

        model.librarySort = LibrarySearchSort(field: .progress)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["paper/\(first.id.wire)", "paper/\(second.id.wire)"])
        model.librarySort = LibrarySearchSort(field: .opened)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["paper/\(second.id.wire)", "paper/\(first.id.wire)"])

        // Chats count saved conversations about each paper; deleted ones don't count.
        var state = model.privateState
        let device = UUID(), kept = UUID(), deleted = UUID()
        for conversation in [kept, deleted, UUID()] {
            try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation,
                entityID: conversation, documentID: conversation == kept || conversation == deleted ? first.id : nil, text: "Chat")))
        }
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: deleted)))
        model.privateState = state
        XCTAssertEqual(model.libraryFacts(for: .paper(first)).chats, 1)
        XCTAssertEqual(model.libraryFacts(for: .paper(second)).chats, 0)
        model.librarySort = LibrarySearchSort(field: .chats)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id).first, "paper/\(first.id.wire)")

        // A sort change keeps the same rows on screen while the new order is computed.
        model.librarySort = .title
        XCTAssertTrue(model.librarySearchKeepsCurrentRows)
        XCTAssertEqual(model.libraryRows.count, 2)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["paper/\(first.id.wire)", "paper/\(second.id.wire)"])
    }
}
