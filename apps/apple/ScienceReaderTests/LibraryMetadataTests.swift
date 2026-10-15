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
                       "Vaswani, Shazeer, Parmar +5")
        XCTAssertEqual(LibraryFormat.shortAuthors(["A B", "C D", "E F"]), "B, D, F")
        XCTAssertNil(LibraryFormat.authorLine([]))
        XCTAssertEqual(LibraryFormat.authorLine(["Ashish Vaswani", "Noam Shazeer"]), "Ashish Vaswani, Noam Shazeer")
        XCTAssertEqual(LibraryFormat.authorLine(["Ashish Vaswani", "Noam Shazeer", "Niki Parmar", "Jakob Uszkoreit",
                                                 "Llion Jones", "Aidan N. Gomez", "Łukasz Kaiser", "Illia Polosukhin"]),
                       "Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit, Llion Jones, Aidan N. Gomez +2")
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
        XCTAssertEqual(LibraryFormat.shortAuthors(for: paper), "He, Zhang, Ren +1")
    }

    /// Owner, build 46: "Should say the exact time please".
    func testTableDatesSayTheTime() {
        let format = { (date: Date) in LibraryFormat.tableDate(date, now: self.now, calendar: self.calendar) }
        let today = format(now - 3_600)
        XCTAssertTrue(today.contains(":") && !today.contains("Today"), today)
        XCTAssertTrue(format(now - day).hasPrefix("Yest. "), format(now - day))
        XCTAssertTrue(format(now - 2 * day).hasPrefix("Sat "), format(now - 2 * day))
        XCTAssertTrue(format(now - 7 * day).hasPrefix("Sep 28, "), format(now - 7 * day))
        XCTAssertEqual(format(now - 372 * day), "Sep 28, 2025", "Earlier years: the date, no time")
        // The table's two-line form: the day, the time under it; earlier years without a time.
        let lines = { (date: Date) in LibraryFormat.tableDateLines(date, now: self.now, calendar: self.calendar) }
        XCTAssertEqual(lines(now - 3_600).day, "Today"); XCTAssertNotNil(lines(now - 3_600).time)
        XCTAssertEqual(lines(now - day).day, "Yest.")
        XCTAssertEqual(lines(now - 7 * day).day, "Sep 28"); XCTAssertNotNil(lines(now - 7 * day).time)
        XCTAssertNil(lines(now - 372 * day).time)
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
        // Categories with a tag-vocabulary equivalent use its names (docs/architecture/TAGS.md).
        XCTAssertEqual(ArxivTopics.names(for: ["cs.CL", "cs.LG", "cs.AI"]), ["Natural language processing", "Machine learning"], "At most two")
        XCTAssertEqual(ArxivTopics.names(for: ["cs.LG", "stat.ML", "cs.CV"]), ["Machine learning", "Computer vision"], "Same name once")
        XCTAssertEqual(ArxivTopics.names(for: ["math.OC"]), ["Optimization"])
        XCTAssertEqual(ArxivTopics.names(for: ["math.ST", "stat.TH", "cs.LG"]), ["Statistics theory", "Machine learning"], "Duplicates collapse")
        XCTAssertEqual(ArxivTopics.name(for: "math.KT"), "Mathematics", "Archive name when the category has none")
        XCTAssertEqual(ArxivTopics.name(for: "hep-th"), "High-energy theory")
        XCTAssertEqual(ArxivTopics.name(for: "attention"), "Attention", "Free-text keywords read as words")
        XCTAssertEqual(ArxivTopics.name(for: "xx.YY"), "xx.YY", "Unknown codes stay as they are")
        XCTAssertTrue(ArxivTopics.names(for: []).isEmpty)
        for (code, name) in ArxivTopics.feedNames {
            XCTAssertEqual(ArxivTopics.name(for: code), TagVocabulary.name(forCategory: code) ?? name, "Vocabulary names, else the Feed's labels")
        }
        XCTAssertEqual(ArxivTopics.name(for: "cs.DC"), "Distributed", "A broader category keeps its own label")
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
            tags: ["Language", "Machine learning"], added: now - 7 * day, opened: now, progress: 0.6, chats: 2, pages: 15,
            status: .none, needsCredits: false)
        let pending = LibraryRowFacts(id: "import/z", title: "Pending", paper: nil, authors: "Kaplan, McCandlish +8", year: 2020,
            tags: [], added: nil, opened: nil, progress: nil, chats: 0, pages: nil, status: .active("Converting…"), needsCredits: false)
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

    // MARK: Import progress (pipeline reliability, 2026-10-06)

    private func importRecord(_ id: UUID = UUID(), phase: String, progress: String? = nil, error: String? = nil,
                              intentRevision: Int = 1, state: Int = 1) throws -> LibraryImportRecord {
        var value: [String: Any] = ["id": id.wire, "created_seq": 1, "state_seq": state, "intent_revision": intentRevision,
            "visible": true, "phase": phase, "source": "arxiv", "source_id": "2006.11239",
            "source_url": "https://arxiv.org/abs/2006.11239", "retryable": phase == "failed"]
        if let progress { value["progress"] = progress }
        if let error { value["error_code"] = error }
        return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testStepTimeIsQuietThenSaysTakingLongerThanUsualAfterThreeMinutes() {
        func elapsed(_ seconds: TimeInterval) -> ImportStepElapsed { ImportStepElapsed(since: now, now: now + seconds) }
        XCTAssertNil(elapsed(0).label, "Nothing in the first minute")
        XCTAssertNil(elapsed(59).label)
        XCTAssertEqual(elapsed(60).label, "1 min")
        XCTAssertEqual(elapsed(179).label, "2 min")
        XCTAssertFalse(elapsed(179).isSlow)
        XCTAssertTrue(elapsed(180).isSlow, "Three minutes in the same step is slow")
        XCTAssertEqual(elapsed(180).label, "Taking longer than usual")
        XCTAssertEqual(elapsed(3 * 3_600).label, "Taking longer than usual")
        XCTAssertEqual(elapsed(-90).seconds, 0, "A clock set back never shows negative time")
        XCTAssertNil(elapsed(-90).label)

        XCTAssertNil(elapsed(30).spokenLabel)
        XCTAssertEqual(elapsed(60).spokenLabel, "1 minute")
        XCTAssertEqual(elapsed(150).spokenLabel, "2 minutes")
        XCTAssertEqual(elapsed(4 * 60 + 10).spokenLabel, "4 minutes, taking longer than usual")
        XCTAssertEqual(elapsed(65 * 60).spokenLabel, "1 hour 5 minutes, taking longer than usual")
        XCTAssertEqual(elapsed(120 * 60).spokenLabel, "2 hours, taking longer than usual")
    }

    func testImportStatusNamesTheStepAndHowLongItHasRun() throws {
        func elapsed(_ seconds: TimeInterval) -> ImportStepElapsed { ImportStepElapsed(since: now, now: now + seconds) }
        let downloading = try importRecord(phase: "acquiring", progress: "downloading")
        let step = try XCTUnwrap(downloading.step)
        XCTAssertEqual(step, .downloading)
        XCTAssertEqual(downloading.libraryStatus, "Downloading…", "Unchanged without a time")
        XCTAssertEqual(downloading.libraryShortStatus, "Downloading…")
        XCTAssertEqual(step.status(short: false, elapsed: nil), "Downloading…")
        XCTAssertEqual(step.status(short: false, elapsed: elapsed(40)), "Downloading…")
        XCTAssertEqual(step.status(short: false, elapsed: elapsed(90)), "Downloading… · 1 min")
        XCTAssertEqual(step.status(short: true, elapsed: elapsed(90)), "Downloading… · 1 min")
        XCTAssertEqual(step.status(short: false, elapsed: elapsed(200)), "Downloading… · Taking longer than usual",
                       "The step's name stays")
        XCTAssertEqual(step.spokenStatus(elapsed: elapsed(40)), "Downloading")
        XCTAssertEqual(step.spokenStatus(elapsed: elapsed(200)), "Downloading, 3 minutes, taking longer than usual")

        // Every phase in progress has a step; the table says only "Downloading…" or "Adding…" (owner, 2026-10-15).
        let expected: [(String, String?, LibraryImportStep, String)] = [
            ("accepted", nil, .queued, "Adding…"),
            ("accepted", "converting", .converting, "Adding…"),
            ("resolving", nil, .finding, "Adding…"),
            ("resolving", "finding", .finding, "Adding…"),
            ("acquiring", nil, .preparing, "Adding…"),
            ("acquiring", "downloading", .downloading, "Downloading…"),
            ("acquiring", "rendering", .building, "Adding…"),
            ("acquiring", "finishing", .building, "Adding…"),
            ("acquiring", "future_progress", .preparing, "Adding…"),
        ]
        for (phase, progress, step, words) in expected {
            let item = try importRecord(phase: phase, progress: progress)
            XCTAssertEqual(item.step, step, "\(phase) \(progress ?? "-")")
            XCTAssertEqual(item.libraryStatus, words)
            XCTAssertEqual(item.libraryShortStatus, words)
        }
        XCTAssertEqual(LibraryImportStep.queued.status(short: false, elapsed: elapsed(130)), "Adding… · 2 min")
        for phase in ["failed", "ready", "cancelled", "source_only", "membership_conflict"] {
            XCTAssertNil(try importRecord(phase: phase).step, "\(phase) is not in progress")
        }
    }

    func testFailedImportsSayWhatFailed() throws {
        let messages: [(String, String, String)] = [
            ("download_failed", "Couldn’t download this paper", "Download failed"),
            ("rate_limited", "Couldn’t download this paper", "Download failed"),
            ("conversion_failed", "Conversion failed", "Conversion failed"),
            ("metadata_unavailable", "Couldn’t get this paper’s details", "Details unavailable"),
            ("too_large", "This PDF is too large to convert", "Too large to convert"),
            ("pdf_invalid", "This PDF couldn’t be read", "PDF unreadable"),
            ("insufficient_credits", "Not enough credits to convert this paper", "Needs credits"),
            ("license_unverified", "Couldn’t confirm this paper’s license", "License unconfirmed"),
            ("something_new", "Couldn’t import this paper", "Import failed"),
        ]
        for (code, full, short) in messages {
            let item = try importRecord(phase: "failed", error: code)
            XCTAssertEqual(item.libraryStatus, full, code)
            XCTAssertEqual(item.libraryShortStatus, short, code)
        }
    }

    func testStepClockKeepsTheStartUntilTheStepChanges() throws {
        var clock = ImportStepClock()
        let id = UUID(), other = UUID()
        let downloading = try importRecord(id, phase: "acquiring", progress: "downloading")
        clock.observe([downloading], now: now)
        XCTAssertEqual(clock.timing(of: downloading), ImportStepTiming(step: .downloading, since: now))

        // Polls that change other fields keep the start; a new import starts its own.
        let polled = try importRecord(id, phase: "acquiring", progress: "downloading", state: 5)
        let queued = try importRecord(other, phase: "accepted")
        clock.observe([polled, queued], now: now + 120)
        XCTAssertEqual(clock.timing(of: polled)?.since, now)
        XCTAssertEqual(clock.timing(of: queued)?.since, now + 120)

        // The next step starts again; rendering and finishing are one step ("Preparing it for reading").
        let converting = try importRecord(id, phase: "acquiring", progress: "converting", state: 6)
        clock.observe([converting, queued], now: now + 300)
        XCTAssertEqual(clock.timing(of: converting), ImportStepTiming(step: .converting, since: now + 300))
        XCTAssertNil(clock.timing(of: polled), "A stale row's step doesn't borrow the new step's time")
        let rendering = try importRecord(id, phase: "acquiring", progress: "rendering", state: 7)
        clock.observe([rendering], now: now + 400)
        let finishing = try importRecord(id, phase: "acquiring", progress: "finishing", state: 8)
        clock.observe([finishing], now: now + 500)
        XCTAssertEqual(clock.timing(of: finishing)?.since, now + 400)
        XCTAssertNil(clock.timing(of: queued), "An import that left the library is forgotten")

        // A failure has no step; a retry (new intent) starts counting again, even in the same step.
        let failed = try importRecord(id, phase: "failed", error: "download_failed", state: 9)
        clock.observe([failed], now: now + 600)
        XCTAssertNil(clock.timing(of: failed))
        let retried = try importRecord(id, phase: "acquiring", progress: "finishing", intentRevision: 2, state: 10)
        clock.observe([retried], now: now + 700)
        XCTAssertEqual(clock.timing(of: retried)?.since, now + 700)
        let retriedAgain = try importRecord(id, phase: "acquiring", progress: "finishing", intentRevision: 3, state: 11)
        clock.observe([retriedAgain], now: now + 800)
        XCTAssertEqual(clock.timing(of: retriedAgain)?.since, now + 800, "A new intent without a seen failure also restarts")
    }

    func testModelTimesImportStepsWithItsClock() throws {
        let model = ReaderModel(configuration: nil)
        var clock = now
        model.importClock = { clock }
        let id = UUID()
        let downloading = try importRecord(id, phase: "acquiring", progress: "downloading")
        model.installLibraryMetadataFixture(papers: [], imports: [downloading], sequences: [:], activity: [:], offline: [:])
        XCTAssertEqual(model.libraryFacts(for: .pending(downloading)).stepTiming, ImportStepTiming(step: .downloading, since: now))
        XCTAssertEqual(model.libraryStatus(for: .pending(downloading)), .active("Downloading…"))

        clock = now + 240
        let polled = try importRecord(id, phase: "acquiring", progress: "downloading", state: 2)
        model.installLibraryMetadataFixture(papers: [], imports: [polled], sequences: [:], activity: [:], offline: [:])
        let timing = try XCTUnwrap(model.libraryFacts(for: .pending(polled)).stepTiming)
        XCTAssertEqual(timing.since, now, "Still the same step")
        XCTAssertTrue(ImportStepElapsed(since: timing.since, now: clock).isSlow)

        let failed = try importRecord(id, phase: "failed", error: "download_failed", state: 3)
        model.installLibraryMetadataFixture(papers: [], imports: [failed], sequences: [:], activity: [:], offline: [:])
        XCTAssertNil(model.libraryFacts(for: .pending(failed)).stepTiming)
        XCTAssertEqual(model.libraryStatus(for: .pending(failed)), .problem("Download failed"))
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
        XCTAssertNil(model.libraryFacts(for: .paper(second)).opened, "Not opened")

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
