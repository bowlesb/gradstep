import Foundation
import ScienceReaderCore

/// An import in progress as its row shows it (owner, 2026-10-07: "an estimate of the total time, … a percent done,
/// with stages that make more sense to the user"). Pure: the server's detail (migration 029) and when this device
/// received it in, the time in, the words, the bar and what VoiceOver reads out. From servers without details it
/// falls back to the step and how long it has run here ("Downloading the PDF · 2 min"), as before.
/// Design: docs/architecture/IMPORT_PROGRESS.md.
struct ImportProgress: Equatable, Sendable {
    /// The step, from the detail when there is one, else from the coarse progress.
    let step: LibraryImportStep
    /// The server's latest detail; nil from servers before migration 029.
    let detail: LibraryImportProgressDetail?
    /// When this device received `detail`: the bar and the time left move on from here until the next one.
    let receivedAt: Date
    /// The highest percent shown so far in this attempt; the bar never moves back.
    var floor = 0
    /// When this device first saw the import on its current step (for the fallback's elapsed time).
    var stepSince: Date? = nil
    /// The failed stage has a server retry scheduled (027/041): shown as work in progress, without a local retry.
    var retrying = false
    /// Keep the reason that this step failed while telling the reader it is scheduled to try again.
    var retryTitle: String? = nil
    var retryCompactTitle: String? = nil
    /// Where the paper's details come from, for a wait's wording ("Waiting for arXiv"); nil when unknown.
    var sourceName: String? = nil

    /// The percent shown at `now`: the server's, moved on toward 99 % at the estimated finish (the same count-down
    /// the server assumes when it decides whether a reader needs a new detail), but never past where the current step
    /// ends for a typical paper (`countCeiling`), never below `floor`, never 100 % (the row turns into the paper then).
    /// Nil without a server percent.
    func percent(at now: Date) -> Int? {
        guard let detail else { return nil }
        var shown = Double(min(99, detail.percent))
        if let eta = detail.etaSeconds, eta > 0, !detail.delayed {
            shown += (99 - shown) * min(1, max(0, now.timeIntervalSince(receivedAt)) / Double(eta))
            shown = min(shown, Double(max(detail.percent, Self.countCeiling(step))))
        }
        return min(99, max(floor, Int(shown.rounded(.down))))
    }

    /// The furthest the bar counts on its own during a step: about where the step ends for a typical paper (the
    /// server's default stage times: details ~10 %, download ~25 %, reading ~75 %). A step that runs long then waits
    /// there instead of reaching "Finding 99%" (owner feedback, build 16 #10); the server's next detail moves it on.
    static func countCeiling(_ step: LibraryImportStep) -> Int {
        switch step {
        case .queued, .finding, .preparing: 15
        case .downloading: 30
        case .converting: 85
        case .building: 99
        case .waiting: 0
        }
    }

    /// Backing off, paused, or well past the estimate: the row shows the step without a percent (an indeterminate
    /// spinner) and says what it is waiting for.
    func isWaiting(at now: Date) -> Bool {
        guard let detail else { return false }
        return detail.delayed || timeLeft(at: now) == .slow
    }

    /// What a waiting import is waiting for, in plain words.
    var waitText: String {
        switch step {
        case .finding where detail?.delayed == true: sourceName.map { "Waiting for \($0) · retrying" } ?? "Waiting to retry"
        case .preparing where detail?.delayed == true, .downloading where detail?.delayed == true: "Waiting to retry"
        default: ImportTimeLeft.slow.text
        }
    }

    /// The time part, if there is anything honest to say.
    func timeLeft(at now: Date) -> ImportTimeLeft? {
        let slowStep = stepSince.map { now.timeIntervalSince($0) >= ImportStepElapsed.slowAfter } ?? false
        guard let detail, !detail.delayed else { return detail?.delayed == true || slowStep ? .slow : nil }
        guard let eta = detail.etaSeconds else { return slowStep ? .slow : nil }
        let elapsed = max(0, now.timeIntervalSince(receivedAt)), total = Double(eta)
        // Well past the estimate with no word from the server: say so rather than "almost done" forever.
        if elapsed > total + max(30, total) { return .slow }
        // Before the page count is known the estimate is for a typical paper: say so, without a count-down.
        guard detail.pages != nil else { return .typical(seconds: eta) }
        let left = total - elapsed
        return left <= 0 ? .almostDone : .left(seconds: Int(left.rounded(.up)))
    }

    /// Two words and a percentage (owner, 2026-10-15: "we only need Downloading… and Preparing… with a total
    /// percentage value"): "Downloading…" while the PDF downloads, "Preparing…" for every other step. The percent is
    /// the server's, counted on as before; a wait or a scheduled retry shows "retrying" beside it instead of a time.
    static func label(for step: LibraryImportStep) -> String { step == .downloading ? "Downloading…" : "Preparing…" }
    static func compactLabel(for step: LibraryImportStep) -> String { step == .downloading ? "Downloading" : "Preparing" }

    func presentation(at now: Date) -> ImportProgressPresentation {
        let title = Self.label(for: step), spokenTitle = Self.compactLabel(for: step)
        if retrying {
            return ImportProgressPresentation(step: step, title: title, detail: nil, percent: nil,
                                              timeText: "retrying", compactTimeText: "retrying", isSlow: false,
                                              accessibilityLabel: "\(spokenTitle), trying again automatically", compactTitleOverride: Self.compactLabel(for: step))
        }
        guard let detail else {
            // Older servers: the step without a percent.
            return ImportProgressPresentation(step: step, title: title, detail: nil, percent: nil, timeText: nil,
                                              compactTimeText: nil, isSlow: false, accessibilityLabel: spokenTitle,
                                              compactTitleOverride: Self.compactLabel(for: step))
        }
        if isWaiting(at: now) {
            // Nothing moves: the word, a spinner, and "retrying" when the server is backing off.
            let wait: String? = detail.delayed ? "retrying" : nil
            return ImportProgressPresentation(step: step, title: title, detail: nil, percent: nil, timeText: wait,
                                              compactTimeText: wait, isSlow: true,
                                              accessibilityLabel: [spokenTitle, wait].compactMap { $0 }.joined(separator: ", "),
                                              compactTitleOverride: Self.compactLabel(for: step))
        }
        let percent = percent(at: now)
        let spoken = [spokenTitle, percent.map { "\($0) percent" }].compactMap { $0 }.joined(separator: ", ")
        return ImportProgressPresentation(step: step, title: title, detail: nil, percent: percent, timeText: nil,
                                          compactTimeText: nil, isSlow: timeLeft(at: now) == .slow, accessibilityLabel: spoken,
                                          compactTitleOverride: Self.compactLabel(for: step))
    }

    /// "page 12 of 27" or "27 pages" while reading; the PDF's size (or pages) while downloading.
    static func detailText(step: LibraryImportStep, detail: LibraryImportProgressDetail) -> String? {
        switch step {
        case .converting:
            guard let pages = detail.pages else { return nil }
            if let done = detail.pagesDone, done > 0 { return "page \(done) of \(pages)" }
            return pages == 1 ? "1 page" : "\(pages) pages"
        case .downloading:
            if let bytes = detail.bytes { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return detail.pages.map { $0 == 1 ? "1 page" : "\($0) pages" }
        default: return nil
        }
    }
}

/// How long is left, in the reader's words.
enum ImportTimeLeft: Equatable, Sendable {
    /// This paper's estimate, counted down: "About 40 s left".
    case left(seconds: Int)
    /// The estimate has run out but it hasn't been long: "Almost done".
    case almostDone
    /// No page count yet, so the estimate is for a typical paper: "Usually under a minute".
    case typical(seconds: Int)
    /// Backing off, paused, or well past the estimate: "Taking longer than usual".
    case slow

    var text: String {
        switch self {
        case .left(let seconds):
            switch Self.rounded(seconds) {
            case .fewSeconds: return "A few seconds left"
            case .seconds(let n): return "About \(n) s left"
            case .minute: return "About a minute left"
            case .minutes(let n): return "About \(n) min left"
            }
        case .almostDone: return "Almost done"
        case .typical(let seconds): return seconds < 50 ? "Usually under a minute" : seconds < 90 ? "Usually about a minute"
            : "Usually about \(Self.wholeMinutes(seconds)) minutes"
        case .slow: return "Taking longer than usual"
        }
    }
    /// Without "About", for a narrow column: "40 s left".
    var compactText: String {
        switch self {
        case .left(let seconds):
            switch Self.rounded(seconds) {
            case .fewSeconds: return "A few seconds"
            case .seconds(let n): return "\(n) s left"
            case .minute: return "1 min left"
            case .minutes(let n): return "\(n) min left"
            }
        case .almostDone: return "Almost done"
        case .typical(let seconds): return seconds < 50 ? "Under a minute" : seconds < 90 ? "About a minute"
            : "About \(Self.wholeMinutes(seconds)) min"
        case .slow: return "Taking longer than usual"
        }
    }
    var spoken: String {
        switch self {
        case .left(let seconds):
            switch Self.rounded(seconds) {
            case .fewSeconds: return "a few seconds left"
            case .seconds(let n): return "about \(n) seconds left"
            case .minute: return "about a minute left"
            case .minutes(let n): return "about \(n) minutes left"
            }
        case .almostDone: return "almost done"
        case .typical(let seconds): return seconds < 50 ? "usually under a minute" : seconds < 90 ? "usually about a minute"
            : "usually about \(Self.wholeMinutes(seconds)) minutes"
        case .slow: return "taking longer than usual"
        }
    }

    enum Rounded: Equatable { case fewSeconds, seconds(Int), minute, minutes(Int) }
    /// Under 10 s: "a few seconds"; under 55 s: to 5 s (under 30 s) or 10 s; under 90 s: "a minute"; then minutes.
    /// Coarse on purpose: the text changes every few seconds at most, and promises nothing finer than we know.
    static func rounded(_ seconds: Int) -> Rounded {
        switch seconds {
        case ..<10: return .fewSeconds
        case ..<30: return .seconds(max(10, Int((Double(seconds) / 5).rounded()) * 5))
        case ..<55: return .seconds(Int((Double(seconds) / 10).rounded()) * 10)
        case ..<90: return .minute
        default: return .minutes(wholeMinutes(seconds))
        }
    }
    static func wholeMinutes(_ seconds: Int) -> Int { max(2, Int((Double(seconds) / 60).rounded())) }
}

/// Everything a row draws for an import in progress at one moment.
struct ImportProgressPresentation: Equatable, Sendable {
    let step: LibraryImportStep
    /// "Reading equations and figures".
    let title: String
    /// "page 12 of 27", "27 pages", "3.4 MB"; nil when there is nothing to add.
    let detail: String?
    /// 0–99, or nil without a server percent (older servers draw a spinner instead of the bar).
    let percent: Int?
    /// "About 40 s left", "Usually under a minute", "Taking longer than usual"; from older servers the step's
    /// elapsed time ("2 min").
    let timeText: String?
    /// The same for a narrow column: "40 s left".
    let compactTimeText: String?
    let isSlow: Bool
    /// One sentence: "Reading equations and figures, page 12 of 27, 62 percent, about 40 seconds left".
    let accessibilityLabel: String
    var compactTitleOverride: String? = nil

    /// The step line: "Reading equations and figures (page 12 of 27)".
    var line: String { detail.map { "\(title) (\($0))" } ?? title }
    /// One word for a narrow column: "Reading".
    var compactTitle: String { compactTitleOverride ?? step.tableTitle }
    /// The bar's value, 0…1.
    var fraction: Double? { percent.map { Double($0) / 100 } }
    /// Beside the bar: "62% · About 40 s left".
    var status: String? {
        let parts = [percent.map { "\($0)%" }, timeText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// When this device received each import's current detail and the highest percent it has shown in the attempt.
/// In memory only (a relaunch counts down from the first detail it sees); nothing is sent anywhere.
struct ImportProgressTracker: Equatable {
    private struct Mark: Equatable {
        let stateSequence: Int64, intentRevision: Int64
        let step: LibraryImportStep
        let detail: LibraryImportProgressDetail?
        let receivedAt: Date
        let floor: Int
    }
    private var marks: [UUID: Mark] = [:]

    /// Keeps each import's mark while its state_seq is unchanged; a new one starts its count-down now, keeping
    /// what the bar showed as its floor unless it is a new attempt (a retry). Forgets imports no longer in progress.
    mutating func observe(_ imports: [LibraryImportRecord], now: Date) {
        var next: [UUID: Mark] = [:]
        for item in imports where item.step != nil {
            let old = marks[item.id]
            if let old, old.stateSequence == item.stateSequence, old.intentRevision == item.intentRevision { next[item.id] = old; continue }
            var floor = 0
            if let old, old.intentRevision == item.intentRevision {
                floor = ImportProgress(step: old.step, detail: old.detail, receivedAt: old.receivedAt, floor: old.floor).percent(at: now) ?? old.floor
            }
            next[item.id] = Mark(stateSequence: item.stateSequence, intentRevision: item.intentRevision, step: item.step ?? .queued,
                                 detail: item.progressDetail, receivedAt: now, floor: floor)
        }
        marks = next
    }

    /// Fixtures: as if the import's current detail arrived at `receivedAt`.
    mutating func record(_ item: LibraryImportRecord, receivedAt: Date) {
        guard item.step != nil else { return }
        marks[item.id] = Mark(stateSequence: item.stateSequence, intentRevision: item.intentRevision, step: item.step ?? .queued,
                              detail: item.progressDetail, receivedAt: receivedAt, floor: marks[item.id]?.floor ?? 0)
    }

    /// The import's progress, or nil when it isn't in progress. `now` stands in for an import not yet observed.
    func progress(of item: LibraryImportRecord, stepSince: Date?, now: Date) -> ImportProgress? {
        if item.isRetryingAutomatically {
            let download = item.errorCode == .downloadRetrying
            let step: LibraryImportStep = item.errorCode == .conversionFailed ? .building : item.retryStep
            return ImportProgress(step: download ? .downloading : step, detail: nil, receivedAt: now, retrying: true,
                                  retryTitle: download ? nil : item.libraryStatus, retryCompactTitle: item.libraryShortStatus)
        }
        guard let step = item.step else { return nil }
        let mark = marks[item.id].flatMap { $0.stateSequence == item.stateSequence && $0.intentRevision == item.intentRevision ? $0 : nil }
        return ImportProgress(step: step, detail: item.progressDetail, receivedAt: mark?.receivedAt ?? now, floor: mark?.floor ?? 0,
                              stepSince: stepSince, sourceName: item.isArxivSource ? "arXiv" : nil)
    }
}

extension LibraryImportRecord {
    /// The server will retry a failed step (027 downloads; 041 metadata/render): rows show the reason and scheduled
    /// retry as under way, and the library keeps polling. A past timestamp stays scheduled until the server updates it.
    var isRetryingAutomatically: Bool { phase == .failed && (autoRetryAt != nil || errorCode == .downloadRetrying) }
    /// An arXiv paper (its details come from arXiv's API).
    var isArxivSource: Bool {
        if let source { return source.lowercased() == "arxiv" }
        return sourceID.map { (try? ArxivReference($0)) != nil } ?? false
    }
}
