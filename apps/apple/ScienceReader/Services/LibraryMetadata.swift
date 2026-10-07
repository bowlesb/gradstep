import Foundation
import ScienceReaderCore

/// Library layout (owner decision 2026-10-05): the List stays the default. "Table" is the app's own sortable table
/// (`PaperTable`) at every width, with as many columns as fit (owner request 2026-10-06); at accessibility text
/// sizes it shows detailed rows instead.
enum LibraryLayout: String, CaseIterable, Sendable {
    case list, detailed, table

    var title: String {
        switch self { case .list: "List"; case .detailed: "Detailed rows"; case .table: "Table" }
    }
}

/// Feed layout: the List (title, authors, abstract, Add) or the same table as the Library's.
enum FeedLayout: String, CaseIterable, Sendable {
    case list, table

    var title: String { self == .list ? "List" : "Table" }
}

/// Friendly names for arXiv categories. The Feed's chips and the Library's Topics share them.
enum ArxivTopics {
    /// The Feed's original labels; unchanged.
    static let feedNames = ["cs.LG": "Machine learning", "cs.CL": "Language", "cs.AI": "AI", "cs.CV": "Vision",
                            "stat.ML": "Statistical ML", "cs.RO": "Robotics", "cs.NE": "Neural computing", "cs.IR": "Retrieval",
                            "math.OC": "Optimization", "cs.CR": "Security", "cs.DC": "Distributed"]
    static let names: [String: String] = feedNames.merging([
        "cs.CY": "Computers and society", "cs.DS": "Algorithms", "cs.GT": "Game theory", "cs.HC": "Human–computer interaction",
        "cs.MA": "Multi-agent systems", "cs.SD": "Sound", "cs.SE": "Software engineering", "cs.SI": "Social networks",
        "cs.PL": "Programming languages", "cs.NI": "Networking", "cs.DB": "Databases", "cs.GR": "Graphics",
        "cs.IT": "Information theory", "cs.LO": "Logic", "cs.CC": "Complexity", "cs.CG": "Computational geometry",
        "cs.DM": "Discrete math", "cs.FL": "Formal languages", "cs.MM": "Multimedia", "cs.SY": "Systems and control",
        "cs.AR": "Hardware", "cs.ET": "Emerging technologies", "cs.PF": "Performance", "cs.OS": "Operating systems",
        "cs.NA": "Numerical analysis", "cs.MS": "Mathematical software", "cs.DL": "Digital libraries", "cs.CE": "Computational science",
        "stat.ME": "Statistical methods", "stat.TH": "Statistics theory", "stat.AP": "Applied statistics", "stat.CO": "Computational statistics",
        "math.PR": "Probability", "math.ST": "Statistics theory", "math.NA": "Numerical analysis", "math.CO": "Combinatorics",
        "math.IT": "Information theory", "math.DS": "Dynamical systems", "math.AP": "PDEs", "math.LO": "Logic",
        "eess.AS": "Audio and speech", "eess.IV": "Image and video", "eess.SP": "Signal processing", "eess.SY": "Systems and control",
        "q-bio.NC": "Neuroscience", "q-bio.QM": "Quantitative biology", "q-bio.BM": "Biomolecules", "q-bio.GN": "Genomics",
        "q-fin.ST": "Statistical finance", "q-fin.CP": "Computational finance", "econ.EM": "Econometrics", "econ.TH": "Economic theory",
        "physics.comp-ph": "Computational physics", "physics.data-an": "Data analysis", "physics.chem-ph": "Chemical physics",
        "quant-ph": "Quantum physics", "cond-mat.stat-mech": "Statistical mechanics", "cond-mat.dis-nn": "Disordered systems",
        "hep-th": "High-energy theory", "hep-ph": "High-energy phenomenology", "hep-ex": "High-energy experiment",
        "gr-qc": "Relativity and cosmology", "astro-ph.CO": "Cosmology", "astro-ph.GA": "Galaxies", "astro-ph.IM": "Astronomy methods",
    ], uniquingKeysWith: { feed, _ in feed })
    /// Archive-level names for categories without their own entry.
    private static let archives = ["cs": "Computer science", "stat": "Statistics", "math": "Mathematics", "eess": "Electrical engineering",
                                   "q-bio": "Quantitative biology", "q-fin": "Quantitative finance", "econ": "Economics",
                                   "physics": "Physics", "cond-mat": "Condensed matter", "astro-ph": "Astrophysics",
                                   "hep-th": "High-energy theory", "hep-ph": "High-energy phenomenology", "hep-ex": "High-energy experiment",
                                   "hep-lat": "Lattice field theory", "nucl-th": "Nuclear theory", "nucl-ex": "Nuclear experiment",
                                   "math-ph": "Mathematical physics", "nlin": "Nonlinear sciences", "quant-ph": "Quantum physics", "gr-qc": "Relativity and cosmology"]

    static func name(for category: String) -> String {
        if let name = names[category] { return name }
        let archive = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        if category.contains("."), let name = archives[archive] { return name }
        if let name = archives[category] { return name }
        // Free-text keywords (the offline sample) read as words, not codes.
        return category.first?.isLowercase == true && !category.contains(".") ? category.prefix(1).uppercased() + category.dropFirst() : category
    }

    /// At most `limit` distinct friendly names, in the paper's own category order.
    static func names(for categories: [String], limit: Int = 2) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for category in categories {
            let name = name(for: category)
            guard seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == limit { break }
        }
        return result
    }
}

/// Compact presentation of library metadata and this device's reading activity. Pure functions:
/// callers pass the clock and calendar so tests are deterministic.
enum LibraryFormat {
    private static let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "phd", "ph.d."]
    private static let particles: Set<String> = ["van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "dos", "das",
                                                 "le", "la", "ter", "ten", "bin", "al", "el"]

    /// "Ashish Vaswani" → "Vaswani"; "Vaswani, Ashish" → "Vaswani"; "Ludwig van Beethoven" → "van Beethoven".
    static func familyName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ",") {
            let family = trimmed[..<comma].trimmingCharacters(in: .whitespaces)
            let rest = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces).lowercased()
            // "Martin Luther King, Jr." keeps its family name before the suffix.
            if !family.isEmpty, !suffixes.contains(rest) { return family }
        }
        var words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, let last = words.last, suffixes.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
            words.removeLast()
        }
        guard var index = words.indices.last else { return trimmed }
        while index > 1, particles.contains(words[index - 1].lowercased()) { index -= 1 }
        return words[index...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ","))
    }

    /// One author → the full name; two → "A, B"; more → "A, B +N" (family names).
    static func shortAuthors(_ names: [String]) -> String? {
        let authors = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch authors.count {
        case 0: return nil
        case 1: return authors[0]
        case 2: return "\(familyName(authors[0])), \(familyName(authors[1]))"
        default: return "\(familyName(authors[0])), \(familyName(authors[1])) +\(authors.count - 2)"
        }
    }

    /// The short form used in the Authors column and detailed rows. Falls back to the joined
    /// display string (the offline sample's byline) when individual names are unknown.
    static func shortAuthors(for paper: Paper) -> String? {
        if let short = shortAuthors(paper.authorNames) { return short }
        let joined = paper.authors.trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Today, Yesterday, a weekday within the past week ("Mon"), "Sep 28" this year, "Sep 2025" before.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }   // a clock running ahead counts as today
        if days == 1 { return "Yesterday" }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        if days < 7 { return date.formatted(style.weekday(.abbreviated)) }
        // Earlier years need the year more than the day, and stay short enough for a column.
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            return date.formatted(style.month(.abbreviated).year())
        }
        return date.formatted(style.month(.abbreviated).day())
    }

    /// In running text: "Opened today", "Added yesterday", "Added Mon", "Added Sep 28".
    static func relativeDayInSentence(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let text = relativeDay(date, now: now, calendar: calendar)
        return text == "Today" || text == "Yesterday" ? text.lowercased() : text
    }

    /// Whole percent, clamped; a nearly finished paper doesn't round up to 100 %.
    static func percent(_ progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let clamped = min(1, max(0, progress))
        return clamped >= 1 ? 100 : min(99, Int((clamped * 100).rounded()))
    }

    static func chats(_ count: Int) -> String { count == 1 ? "1 chat" : "\(count) chats" }

    /// The table's author line: one author → the full name; more → "Vaswani et al.".
    static func firstAuthor(_ names: [String]) -> String? {
        let authors = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = authors.first else { return nil }
        return authors.count == 1 ? first : familyName(first) + " et al."
    }

    /// Falls back to the joined display string (the offline sample's byline) when individual names are unknown.
    static func firstAuthor(for paper: Paper) -> String? {
        if let first = firstAuthor(paper.authorNames) { return first }
        let joined = paper.authors.trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

/// The step an import in progress is on, as its row names it.
enum LibraryImportStep: Equatable, Sendable {
    case queued, finding, preparing, downloading, converting, building

    /// The list's name for the step.
    var title: String {
        switch self {
        case .queued: "Queued"; case .finding: "Finding paper"; case .preparing: "Preparing PDF"
        case .downloading: "Downloading PDF"; case .converting: "Converting equations and figures"; case .building: "Building reader"
        }
    }
    /// Short enough for a table column.
    var shortTitle: String {
        switch self { case .downloading: "Downloading"; case .converting: "Converting"; default: title }
    }
    /// One word, beside a spinner in the table's Progress column.
    var tableTitle: String {
        switch self {
        case .queued: "Queued"; case .finding: "Finding"; case .preparing: "Preparing"
        case .downloading: "Downloading"; case .converting: "Converting"; case .building: "Building"
        }
    }
    /// "Downloading PDF…"; waiting in the queue has no ellipsis.
    func label(short: Bool) -> String {
        let name = short ? shortTitle : title
        return self == .queued ? name : name + "…"
    }
    /// The status line with how long the step has run: "Downloading PDF · 1 min", then past three minutes
    /// "Downloading PDF · Taking longer than usual". In the first minute, the plain label.
    func status(short: Bool, elapsed: ImportStepElapsed?) -> String {
        guard let suffix = elapsed?.label else { return label(short: short) }
        return (short ? shortTitle : title) + " · " + suffix
    }
    /// What VoiceOver reads: "Downloading PDF, 4 minutes, taking longer than usual".
    func spokenStatus(elapsed: ImportStepElapsed?) -> String {
        guard let time = elapsed?.spokenLabel else { return title }
        return title + ", " + time
    }
}

/// How long an import has been on its current step, as this device has seen it.
struct ImportStepElapsed: Equatable {
    /// Past this, the row says the step is taking longer than usual (pipeline reliability, 2026-10-06).
    static let slowAfter: TimeInterval = 3 * 60
    let seconds: TimeInterval

    init(since start: Date, now: Date) { seconds = max(0, now.timeIntervalSince(start)) }

    var minutes: Int { Int(seconds / 60) }
    var isSlow: Bool { seconds >= Self.slowAfter }
    /// After the step's name: nothing in the first minute, then "1 min", "2 min", then "Taking longer than usual".
    var label: String? { isSlow ? "Taking longer than usual" : minutes > 0 ? "\(minutes) min" : nil }
    /// "2 minutes"; "1 hour 5 minutes, taking longer than usual"; nothing in the first minute.
    var spokenLabel: String? {
        guard minutes > 0 else { return nil }
        let hours = minutes / 60, rest = minutes % 60
        let time = ((hours > 0 ? [hours == 1 ? "1 hour" : "\(hours) hours"] : [])
            + (rest > 0 ? [rest == 1 ? "1 minute" : "\(rest) minutes"] : [])).joined(separator: " ")
        return isSlow ? time + ", taking longer than usual" : time
    }
}

/// When this device first saw each import in progress on its current step. In memory only: a relaunch starts
/// counting again and nothing is sent anywhere (the server's own step timings feed the admin Reliability tab).
struct ImportStepClock: Equatable {
    private struct Mark: Equatable { let step: LibraryImportStep; let intentRevision: Int64; let since: Date }
    private var marks: [UUID: Mark] = [:]

    /// Keeps the start of imports still on the same step, starts the clock for a new step (or a retry), and
    /// forgets imports that finished, failed or left the library.
    mutating func observe(_ imports: [LibraryImportRecord], now: Date) {
        var next: [UUID: Mark] = [:]
        for item in imports {
            guard let step = item.step else { continue }
            if let mark = marks[item.id], mark.step == step, mark.intentRevision == item.intentRevision { next[item.id] = mark }
            else { next[item.id] = Mark(step: step, intentRevision: item.intentRevision, since: now) }
        }
        marks = next
    }

    /// Records that the import entered its current step at `since` (fixtures).
    mutating func record(_ item: LibraryImportRecord, since: Date) {
        guard let step = item.step else { return }
        marks[item.id] = Mark(step: step, intentRevision: item.intentRevision, since: since)
    }

    /// The step the import is on now and since when; nil when it isn't in progress or this device hasn't seen
    /// that step (the row then shows the plain status).
    func timing(of item: LibraryImportRecord) -> ImportStepTiming? {
        guard let step = item.step, let mark = marks[item.id], mark.step == step,
              mark.intentRevision == item.intentRevision else { return nil }
        return ImportStepTiming(step: step, since: mark.since)
    }
}

/// An import's current step and when this device first saw it there.
struct ImportStepTiming: Equatable {
    let step: LibraryImportStep
    let since: Date
}

extension LibraryImportRecord {
    /// The step while the import is in progress, from the server's progress when known (an import can still
    /// read "accepted" while its paper is already converting), else from its phase.
    var step: LibraryImportStep? {
        switch phase {
        case .accepted, .resolving, .acquiring:
            switch progress {
            case .finding: .finding
            case .downloading: .downloading
            case .converting: .converting
            case .rendering, .finishing: .building
            default: phase == .accepted ? .queued : phase == .resolving ? .finding : .preparing
            }
        default: nil
        }
    }
    /// The list's full status line. Failures say what failed in plain words.
    var libraryStatus: String {
        switch phase {
        case .accepted, .resolving, .acquiring: return step?.label(short: false) ?? "Queued"
        case .sourceOnly: return "Available at source"
        case .failed:
            switch errorCode {
            case .insufficientCredits: return "Not enough credits to convert this paper"
            case .tooLarge: return "This PDF is too large to convert"
            case .pdfInvalid: return "This PDF couldn’t be read"
            case .conversionFailed: return "Conversion failed"
            case .downloadFailed, .rateLimited: return "Couldn’t download this paper"
            case .metadataUnavailable: return "Couldn’t get this paper’s details"
            case .licenseUnverified: return "Couldn’t confirm this paper’s license"
            default: return "Couldn’t import this paper"
            }
        case .membershipConflict: return "Not added to library"
        case .ready: return "Added"
        case .cancelled: return "Cancelled"
        }
    }
    /// The same status, short enough for a table column.
    var libraryShortStatus: String {
        switch phase {
        case .accepted, .resolving, .acquiring: return step?.label(short: true) ?? "Queued"
        case .failed:
            switch errorCode {
            case .insufficientCredits: return "Needs credits"
            case .tooLarge: return "Too large to convert"
            case .pdfInvalid: return "PDF unreadable"
            case .conversionFailed: return "Conversion failed"
            case .downloadFailed, .rateLimited: return "Download failed"
            case .metadataUnavailable: return "Details unavailable"
            case .licenseUnverified: return "License unconfirmed"
            default: return "Import failed"
            }
        default: return libraryStatus
        }
    }
    var isActive: Bool { [.resolving, .acquiring].contains(phase) }
}

/// Everything the Table and detailed rows show for one library entry.
struct LibraryRowFacts {
    enum Status: Equatable {
        case none                    // ready: never a noisy "Ready" label
        case active(String)          // finding / converting, with a spinner
        case info(String)            // queued, not downloaded
        case problem(String)         // failed, needs credits, not converted, unavailable
    }
    let id: String
    let title: String
    let paper: Paper?
    let authors: String?
    let year: Int?
    let topics: [String]
    let added: Date?
    let opened: Date?
    let progress: Double?
    let chats: Int
    let pages: Int?
    let status: Status
    let needsCredits: Bool
    /// An import in progress: its step and when this device first saw it there.
    var stepTiming: ImportStepTiming? = nil

    var statusText: String? {
        switch status { case .none: nil; case .active(let text), .info(let text), .problem(let text): text }
    }

    /// Line 2 of a detailed row: "Vaswani, Shazeer +6 · 2017 · Language, Machine learning".
    func summaryLine(showTopics: Bool) -> String {
        ([authors, year.map(String.init)].compactMap { $0 } + (showTopics && !topics.isEmpty ? [topics.joined(separator: ", ")] : []))
            .joined(separator: " · ")
    }

    /// Line 3: "Added Mon · Opened today · 60% read · 2 chats". Unknown facts are left out.
    func activityLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let added { parts.append("Added " + LibraryFormat.relativeDayInSentence(added, now: now, calendar: calendar)) }
        if paper != nil {
            if let opened { parts.append("Opened " + LibraryFormat.relativeDayInSentence(opened, now: now, calendar: calendar)) }
            else { parts.append("Not opened") }
        }
        if let progress { parts.append("\(LibraryFormat.percent(progress))% read") }
        if chats > 0 { parts.append(LibraryFormat.chats(chats)) }
        return parts.joined(separator: " · ")
    }
}
