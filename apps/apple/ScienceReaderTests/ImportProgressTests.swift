import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Import progress (owner, 2026-10-07): the step in the reader's words, a percent that never goes back, and a time
/// left that is rounded, counted down from when the detail arrived, and only shown when it can be trusted.
@MainActor
final class ImportProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_201_600)

    private func record(_ id: UUID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000030")!, phase: String = "acquiring",
                        progress: String? = "converting", detail: [String: Any]? = nil, state: Int64 = 1,
                        intentRevision: Int64 = 1) throws -> LibraryImportRecord {
        var value: [String: Any] = ["id": id.wire, "created_seq": 1, "state_seq": state, "intent_revision": intentRevision,
            "visible": phase != "ready", "phase": phase, "source": "arxiv", "source_id": "2006.11239",
            "source_url": "https://arxiv.org/abs/2006.11239", "retryable": phase == "failed"]
        if let progress { value["progress"] = progress }
        if phase == "failed" { value["error_code"] = "download_failed" }
        if let detail { value["progress_detail"] = detail }
        return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func progress(_ detail: LibraryImportProgressDetail?, step: LibraryImportStep = .converting, floor: Int = 0,
                          stepSince: Date? = nil) -> ImportProgress {
        ImportProgress(step: step, detail: detail, receivedAt: now, floor: floor, stepSince: stepSince)
    }

    // MARK: Words

    func testStepsUseTheReadersWords() throws {
        let cases: [(String, LibraryImportStep, String, String)] = [
            ("finding", .finding, "Preparing…", "Preparing"),
            ("downloading", .downloading, "Downloading…", "Downloading"),
            ("reading_equations", .converting, "Preparing…", "Preparing"),
            ("preparing", .building, "Preparing…", "Preparing"),
            ("waiting", .waiting, "Preparing…", "Preparing"),
        ]
        for (wire, step, title, word) in cases {
            // The detail's step wins over the coarse progress, which may lag or be less exact.
            let item = try record(progress: "downloading", detail: ["step": wire, "percent": 50])
            XCTAssertEqual(item.step, step, wire)
            let shown = progress(item.progressDetail, step: step).presentation(at: now)
            XCTAssertEqual(shown.title, title)
            XCTAssertEqual(shown.compactTitle, word)
        }
        // A step this build doesn't know falls back to the coarse progress.
        XCTAssertEqual(try record(progress: "converting", detail: ["step": "polishing", "percent": 50]).step, .converting)
        XCTAssertNil(try record(phase: "failed", progress: nil, detail: ["step": "finding", "percent": 3]).step, "Failed: not in progress")
        for word in ["Converting", "converting", "render", "reader", "Building"] {
            for step in [LibraryImportStep.queued, .finding, .preparing, .downloading, .converting, .building, .waiting] {
                XCTAssertFalse(step.title.contains(word) || step.shortTitle.contains(word) || step.tableTitle.contains(word),
                               "No jargon: \(step.title)")
            }
        }
    }

    func testTheStepLineSaysWhichPageOrHowBig() {
        let reading = progress(.init(step: .readingEquations, percent: 62, etaSeconds: 40, pages: 27, pagesDone: 12)).presentation(at: now)
        XCTAssertEqual(reading.line, "Preparing…", "Two words and a percentage: no page counts or times")
        XCTAssertEqual(reading.status, "62%")
        XCTAssertEqual(reading.fraction, 0.62)
        XCTAssertEqual(reading.accessibilityLabel, "Preparing, 62 percent")

        let started = progress(.init(step: .readingEquations, percent: 30, etaSeconds: 50, pages: 27, pagesDone: 0)).presentation(at: now)
        XCTAssertEqual(started.line, "Preparing…")
        let size = progress(.init(step: .downloading, percent: 14, etaSeconds: 52, pages: 45, bytes: 40_817_183), step: .downloading)
            .presentation(at: now)
        XCTAssertEqual(size.line, "Downloading…")
        let pagesOnly = progress(.init(step: .downloading, percent: 14, etaSeconds: 52, pages: 1), step: .downloading).presentation(at: now)
        XCTAssertEqual(pagesOnly.line, "Downloading…")
        let preparing = progress(.init(step: .preparing, percent: 91, etaSeconds: 6, pages: 12), step: .building).presentation(at: now)
        XCTAssertEqual(preparing.line, "Preparing…")
        XCTAssertEqual(preparing.status, "91%")
    }

    // MARK: Time left

    func testTimeLeftIsRoundedAndNeverFinerThanWeKnow() {
        let expected: [(Int, String, String, String)] = [
            (3, "A few seconds left", "A few seconds", "a few seconds left"),
            (9, "A few seconds left", "A few seconds", "a few seconds left"),
            (10, "About 10 s left", "10 s left", "about 10 seconds left"),
            (12, "About 10 s left", "10 s left", "about 10 seconds left"),
            (13, "About 15 s left", "15 s left", "about 15 seconds left"),
            (29, "About 30 s left", "30 s left", "about 30 seconds left"),
            (42, "About 40 s left", "40 s left", "about 40 seconds left"),
            (47, "About 50 s left", "50 s left", "about 50 seconds left"),
            (54, "About 50 s left", "50 s left", "about 50 seconds left"),
            (55, "About a minute left", "1 min left", "about a minute left"),
            (89, "About a minute left", "1 min left", "about a minute left"),
            (90, "About 2 min left", "2 min left", "about 2 minutes left"),
            (200, "About 3 min left", "3 min left", "about 3 minutes left"),
        ]
        for (seconds, text, compact, spoken) in expected {
            let left = ImportTimeLeft.left(seconds: seconds)
            XCTAssertEqual(left.text, text, "\(seconds)"); XCTAssertEqual(left.compactText, compact); XCTAssertEqual(left.spoken, spoken)
        }
        XCTAssertEqual(ImportTimeLeft.typical(seconds: 47).text, "Usually under a minute")
        XCTAssertEqual(ImportTimeLeft.typical(seconds: 70).text, "Usually about a minute")
        XCTAssertEqual(ImportTimeLeft.typical(seconds: 200).text, "Usually about 3 minutes")
        XCTAssertEqual(ImportTimeLeft.slow.text, "Taking longer than usual")
    }

    func testTimeLeftCountsDownFromWhenTheDetailArrived() {
        let reading = progress(.init(step: .readingEquations, percent: 60, etaSeconds: 40, pages: 27, pagesDone: 12))
        XCTAssertEqual(reading.timeLeft(at: now), .left(seconds: 40))
        XCTAssertEqual(reading.timeLeft(at: now + 25), .left(seconds: 15))
        XCTAssertEqual(reading.timeLeft(at: now + 40), .almostDone, "Run out, recently: almost done")
        XCTAssertEqual(reading.timeLeft(at: now + 79), .almostDone)
        XCTAssertEqual(reading.timeLeft(at: now + 81), .slow, "Well past the estimate (twice it, at least 30 s): no false promise")
        XCTAssertEqual(reading.timeLeft(at: now - 30), .left(seconds: 40), "A clock set back never adds time")

        let quick = progress(.init(step: .preparing, percent: 95, etaSeconds: 4, pages: 12), step: .building)
        XCTAssertEqual(quick.timeLeft(at: now + 20), .almostDone)
        XCTAssertEqual(quick.timeLeft(at: now + 35), .slow, "At least 30 s of grace")
    }

    func testUncertainEstimatesAreNotCountedDown() {
        // No page count yet: a typical paper's time, said loosely.
        let finding = progress(.init(step: .finding, percent: 0, etaSeconds: 47), step: .finding)
        XCTAssertEqual(finding.presentation(at: now + 10).status, "\(finding.percent(at: now + 10)!)%")
        XCTAssertEqual(finding.timeLeft(at: now + 30), .typical(seconds: 47))
        XCTAssertEqual(finding.timeLeft(at: now + 95), .slow)
        // Backing off after an error, or paused: no estimate and no percent (build 16 #10), and it says so.
        let delayed = progress(.init(step: .readingEquations, percent: 41, delayed: true, pages: 25, pagesDone: 9))
        let shown = delayed.presentation(at: now + 600)
        XCTAssertEqual(shown.status, "retrying")
        XCTAssertTrue(shown.isSlow)
        XCTAssertNil(shown.percent, "No percent while it waits: the row shows a spinner")
        XCTAssertEqual(shown.accessibilityLabel, "Preparing, retrying")
        // A detail without an estimate (not delayed): quiet, until the step has run three minutes here.
        let quiet = progress(.init(step: .readingEquations, percent: 41, pages: 25), stepSince: now)
        XCTAssertNil(quiet.timeLeft(at: now + 60))
        XCTAssertEqual(quiet.timeLeft(at: now + 180), .slow)
    }

    // MARK: Percent

    func testPercentMovesOnTowardTheFinishAndNeverBack() {
        let reading = progress(.init(step: .readingEquations, percent: 60, etaSeconds: 40, pages: 27, pagesDone: 12))
        XCTAssertEqual(reading.percent(at: now), 60)
        XCTAssertEqual(reading.percent(at: now + 20), 79, "Halfway to the estimate: halfway from 60 to 99")
        XCTAssertEqual(reading.percent(at: now + 40), 85, "Reading waits where reading usually ends")
        let preparing = progress(.init(step: .preparing, percent: 90, etaSeconds: 10, pages: 27), step: .building)
        XCTAssertEqual(preparing.percent(at: now + 10), 99)
        XCTAssertEqual(preparing.percent(at: now + 400), 99, "Never 100: the row becomes the paper")
        XCTAssertEqual(progress(.init(step: .readingEquations, percent: 30, etaSeconds: 40, pages: 27), floor: 45).percent(at: now), 45)
        XCTAssertEqual(progress(.init(step: .readingEquations, percent: 100, pages: 27)).percent(at: now), 99)
        XCTAssertEqual(progress(.init(step: .readingEquations, percent: 90, etaSeconds: 40, pages: 27)).percent(at: now + 30), 90,
                       "A server percent past the step’s usual end holds until the next detail")
    }

    /// Owner feedback, build 16 #10: "Finding 99% · Taking longer than usual" while arXiv rate-limited the details.
    /// The bar no longer counts past the step, and a waiting import shows the step, a spinner and what it waits for.
    func testAStuckStepNeverShowsANearlyDonePercent() throws {
        let finding = ImportProgress(step: .finding, detail: .init(step: .finding, percent: 3, etaSeconds: 47), receivedAt: now,
                                     sourceName: "arXiv")
        XCTAssertEqual(finding.percent(at: now + 47), 15, "Finding counts no further than where finding usually ends")
        XCTAssertEqual(finding.percent(at: now + 80), 15)
        let late = finding.presentation(at: now + 200)
        XCTAssertNil(late.percent, "Well past the estimate: no percent")
        XCTAssertNil(late.timeText, "No time estimates (two words and a percentage)")
        XCTAssertNil(late.status)

        // The server says it is backing off: what it is waiting for, even if an earlier count reached 99.
        let backingOff = ImportProgress(step: .finding, detail: .init(step: .finding, percent: 5, delayed: true), receivedAt: now,
                                        floor: 99, sourceName: "arXiv")
        let shown = backingOff.presentation(at: now + 1)
        XCTAssertNil(shown.percent)
        XCTAssertNil(shown.fraction, "An indeterminate spinner, not a bar")
        XCTAssertEqual(shown.timeText, "retrying")
        XCTAssertEqual(shown.compactTimeText, "retrying")
        XCTAssertEqual(shown.accessibilityLabel, "Preparing, retrying")
        let web = ImportProgress(step: .finding, detail: .init(step: .finding, percent: 5, delayed: true), receivedAt: now)
        XCTAssertEqual(web.presentation(at: now).timeText, "retrying")
        let download = ImportProgress(step: .downloading, detail: .init(step: .downloading, percent: 20, delayed: true), receivedAt: now)
        XCTAssertEqual(download.presentation(at: now).timeText, "retrying")

        // The tracker names arXiv for an arXiv import.
        var tracker = ImportProgressTracker()
        let item = try record(progress: "finding", detail: ["step": "finding", "percent": 5, "delayed": true])
        tracker.observe([item], now: now)
        XCTAssertEqual(tracker.progress(of: item, stepSince: nil, now: now)?.presentation(at: now).timeText, "retrying")
    }

    func testTrackerKeepsTheBarFromGoingBackUntilARetry() throws {
        var tracker = ImportProgressTracker()
        let id = UUID()
        let first = try record(id, detail: ["step": "reading_equations", "percent": 60, "eta_seconds": 40, "pages": 27], state: 4)
        tracker.observe([first], now: now)
        XCTAssertEqual(tracker.progress(of: first, stepSince: nil, now: now + 999)?.receivedAt, now, "Counted from when it arrived")
        // The same state_seq again (a refresh): the same count-down.
        tracker.observe([first], now: now + 10)
        XCTAssertEqual(tracker.progress(of: first, stepSince: nil, now: now + 10)?.percent(at: now + 10), 69)

        // A new detail 20 s later says less than the bar shows (the paper turned out longer): the bar holds.
        let longer = try record(id, detail: ["step": "reading_equations", "percent": 55, "eta_seconds": 90, "pages": 80], state: 5)
        tracker.observe([longer], now: now + 20)
        let held = try XCTUnwrap(tracker.progress(of: longer, stepSince: nil, now: now + 20))
        XCTAssertEqual(held.receivedAt, now + 20)
        XCTAssertEqual(held.floor, 79)
        XCTAssertEqual(held.percent(at: now + 20), 79)
        XCTAssertEqual(held.timeLeft(at: now + 20), .left(seconds: 90), "The new estimate replaces the old one")

        // A retry is a new attempt: its own percent.
        let failed = try record(id, phase: "failed", progress: nil, state: 6)
        tracker.observe([failed], now: now + 30)
        XCTAssertNil(tracker.progress(of: failed, stepSince: nil, now: now + 30))
        let retried = try record(id, progress: "downloading", detail: ["step": "downloading", "percent": 12, "eta_seconds": 50], state: 7,
                                 intentRevision: 2)
        tracker.observe([retried], now: now + 40)
        XCTAssertEqual(tracker.progress(of: retried, stepSince: nil, now: now + 40)?.percent(at: now + 40), 12)
        let retriedAgain = try record(id, progress: "downloading", detail: ["step": "downloading", "percent": 5, "eta_seconds": 50], state: 8,
                                      intentRevision: 3)
        tracker.observe([retriedAgain], now: now + 50)
        XCTAssertEqual(tracker.progress(of: retriedAgain, stepSince: nil, now: now + 50)?.floor, 0, "Even without a failure seen in between")
    }

    // MARK: Older servers

    func testWithoutADetailTheRowIsAsBefore() throws {
        let item = try record(progress: "downloading")
        XCTAssertNil(item.progressDetail)
        let old = progress(nil, step: try XCTUnwrap(item.step), stepSince: now)
        let first = old.presentation(at: now + 30)
        XCTAssertNil(first.fraction, "No bar: the spinner")
        XCTAssertNil(first.status)
        XCTAssertEqual(first.accessibilityLabel, "Downloading")
        let later = old.presentation(at: now + 200)
        XCTAssertNil(later.timeText, "Older servers: the word alone, no elapsed time")
        XCTAssertFalse(later.isSlow)
        XCTAssertEqual(later.accessibilityLabel, "Downloading")
        XCTAssertNil(old.presentation(at: now + 90).timeText)
    }

    func testADownloadTheServerWillRetryIsNotADeadFailure() throws {
        var value = try record(phase: "failed", progress: nil)
        XCTAssertNil(ImportProgressTracker().progress(of: value, stepSince: nil, now: now), "An ordinary failure has no progress")
        value = try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().wire, "created_seq": 1, "state_seq": 2, "intent_revision": 1, "visible": true, "phase": "failed",
            "source": "arxiv", "source_id": "2006.11239", "source_url": "https://arxiv.org/abs/2006.11239", "retryable": false,
            "error_code": "download_retrying", "auto_retry_at": "2026-10-07T10:00:00Z"] as [String: Any]))
        XCTAssertTrue(value.isRetryingAutomatically)
        let shown = try XCTUnwrap(ImportProgressTracker().progress(of: value, stepSince: nil, now: now)).presentation(at: now)
        XCTAssertEqual(shown.title, "Downloading…")
        XCTAssertEqual(shown.timeText, "retrying")
        XCTAssertNil(shown.fraction, "Waiting, not measured: the spinner")
        XCTAssertFalse(shown.isSlow)
        let model = ReaderModel(configuration: nil)
        XCTAssertEqual(model.libraryStatus(for: .pending(value)), .active("Downloading…"), "Under way in the table, not a problem")
    }

    func testMetadataAndRenderRetriesKeepTheirReasonAndNeverPretendToDownload() throws {
        for (code, reason, compact) in [("metadata_unavailable", "Couldn’t get this paper’s details", "Details unavailable"),
                                        ("conversion_failed", "Conversion failed", "Conversion failed")] {
            var row: [String: Any] = ["id": UUID().wire, "created_seq": 1, "state_seq": 2, "intent_revision": 1,
                "visible": true, "phase": "failed", "source": "arxiv", "source_id": "2006.11239",
                "source_url": "https://arxiv.org/abs/2006.11239", "retryable": true,
                "error_code": code, "auto_retry_at": "2026-10-07T10:00:00Z"]
            let value = try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: row))
            XCTAssertTrue(value.isRetryingAutomatically)
            let shown = try XCTUnwrap(ImportProgressTracker().progress(of: value, stepSince: nil, now: now)).presentation(at: now)
            _ = (reason, compact)
            XCTAssertEqual(shown.title, "Preparing…", "A metadata or render retry never pretends to download")
            XCTAssertEqual(shown.compactTitle, "Preparing")
            XCTAssertEqual(shown.timeText, "retrying")
            XCTAssertEqual(shown.accessibilityLabel, "Preparing, trying again automatically")
            XCTAssertNil(shown.fraction)
            XCTAssertNil(LibraryImportAction.available(for: value, retrying: false), "Scheduled work doesn't compete with a Retry button")
            XCTAssertFalse(LibraryFilter.failed.includesImport(value.phase, retryingAutomatically: value.isRetryingAutomatically))
            row["phase"] = "ready"
            let done = try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: row))
            XCTAssertFalse(done.isRetryingAutomatically, "A stale optional timestamp never revives completed work")
        }
    }

    // MARK: Model

    func testModelGivesRowsTheProgressWithItsClock() throws {
        let model = ReaderModel(configuration: nil)
        var clock = now
        model.importClock = { clock }
        let id = UUID()
        let reading = try record(id, detail: ["step": "reading_equations", "percent": 62, "eta_seconds": 40, "pages": 27, "pages_done": 12])
        model.installLibraryMetadataFixture(papers: [], imports: [reading], sequences: [:], activity: [:], offline: [:])
        let facts = model.libraryFacts(for: .pending(reading))
        let shown = try XCTUnwrap(facts.importProgress).presentation(at: now + 20)
        XCTAssertEqual(shown.line, "Preparing…")
        XCTAssertEqual(shown.status, "80%")
        XCTAssertEqual(model.libraryStatus(for: .pending(reading)), .active("Preparing…"))

        clock = now + 30
        let ready = try record(id, phase: "ready", progress: nil, state: 2)
        model.installLibraryMetadataFixture(papers: [], imports: [ready], sequences: [:], activity: [:], offline: [:])
        XCTAssertNil(model.libraryFacts(for: .pending(ready)).importProgress, "Nothing in progress")
    }
}
