import Foundation
import ScienceReaderCore

/// Library layout. The Table (the app's own sortable table, `PaperTable`) is the Library's main view at every size
/// (owner request 2026-10-07: "it should be a proper table"); the List is the compact alternative. At accessibility
/// text sizes the table shows the List's rows. "Detailed rows" was removed (2026-10-07).
enum LibraryLayout: String, CaseIterable, Sendable {
    case table, list

    var title: String { self == .list ? "List" : "Table" }

    /// A saved choice. Only an explicit List stays the List; "detailed" (removed) and no choice open the Table.
    init(saved: String?) { self = saved == LibraryLayout.list.rawValue ? .list : .table }
}

/// Feed layout: the List (title, authors, abstract, Add) or the same table as the Library's.
enum FeedLayout: String, CaseIterable, Sendable {
    case list, table

    var title: String { self == .list ? "List" : "Table" }
}

/// Friendly names for arXiv categories. The Feed's chips and the Library's Topics share them. Categories the tag
/// vocabulary maps ("cs.CL" → "Natural language processing") use its names, so topics and tags read the same
/// everywhere (docs/architecture/TAGS.md); other categories keep these labels.
enum ArxivTopics {
    /// The Feed's original labels, for categories outside the tag vocabulary.
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
        if let name = TagVocabulary.name(forCategory: category) { return name }
        if let name = names[category] { return name }
        let archive = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        if category.contains("."), let name = archives[archive] { return name }
        if let name = archives[category] { return name }
        // Free-text keywords (the offline sample) read as words, not codes.
        return category.first?.isLowercase == true && !category.contains(".") ? category.prefix(1).uppercased() + category.dropFirst() : category
    }

    /// At most `limit` distinct friendly names, in the paper's own category order.
    static func names(for categories: [String], limit: Int = 2) -> [String] {
        guard limit > 0 else { return [] }
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

/// A paper's tags as the Library shows and filters them: its own tags (display names) when it has any, else topic
/// names derived from its arXiv categories (the Feed chips' names).
enum LibraryTags {
    static func tags(for paper: Paper) -> [String] {
        let own = distinct(paper.tags)
        return own.isEmpty ? ArxivTopics.names(for: paper.keywords, limit: .max) : own
    }

    static func tags(for item: LibraryImportRecord) -> [String] {
        ArxivTopics.names(for: item.metadata?.categories ?? [], limit: .max)
    }

    /// Trimmed, non-empty, first spelling of each kept (case-insensitive).
    static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// The tag filter's choices: each tag with how many rows carry it, most used first, then A to Z.
    static func counts(_ rows: [[String]]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for tags in rows { for tag in Set(tags) { counts[tag, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }
}

/// The Source column: the arXiv identifier, or for a web paper the host it came from ("nature.com").
enum LibrarySourceLabel {
    static func label(sourceID: String?, url: String?) -> String? {
        guard let sourceID, !sourceID.isEmpty else { return nil }
        if LibrarySource.isUploadSourceID(sourceID) { return "Your PDF" }
        guard LibrarySource.isWebSourceID(sourceID) else { return sourceID }
        return url.flatMap(host) ?? "Open access"
    }

    /// "arXiv 1706.03762", "From nature.com".
    static func spoken(sourceID: String?, url: String?) -> String? {
        guard let label = label(sourceID: sourceID, url: url) else { return nil }
        if let sourceID, LibrarySource.isUploadSourceID(sourceID) { return "Your uploaded PDF" }
        guard let sourceID, LibrarySource.isWebSourceID(sourceID) else { return "arXiv " + label }
        return label == "Open access" ? label : "From " + label
    }

    static func host(_ url: String) -> String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty, host != "openalex.org" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The Library's quick filters (owner request 2026-10-07: "people can navigate and find papers easily"). Reading
/// states are this device's own activity; Failed is imports that stopped; Archived replaces Show › Archived papers.
enum LibraryFilter: String, CaseIterable, Sendable {
    case all, unread, reading, failed, archived

    var title: String {
        switch self {
        case .all: "All"; case .unread: "Unread"; case .reading: "Reading"; case .failed: "Failed"; case .archived: "Archived"
        }
    }
    /// What the empty filter says ("No unread papers").
    var emptyTitle: String {
        switch self {
        case .all: "No papers"; case .unread: "No unread papers"; case .reading: "Nothing in progress"
        case .failed: "No failed imports"; case .archived: "No archived papers"
        }
    }
    /// Membership depends on this device's reading activity.
    var usesActivity: Bool { self == .unread || self == .reading }

    /// A paper: Unread was never opened here; Reading was opened (or has progress) and isn't finished.
    func includesPaper(archived: Bool, opened: Date?, progress: Double?) -> Bool {
        switch self {
        case .all: return !archived
        case .archived: return archived
        case .failed: return false
        case .unread: return !archived && opened == nil && (progress ?? 0) <= 0
        case .reading:
            return !archived && (opened != nil || (progress ?? 0) > 0) && LibraryFormat.percent(progress ?? 0) < 100
        }
    }

    /// An import shows under All, and under Failed once it has stopped (one the server is retrying by itself is
    /// still under way).
    func includesImport(_ phase: LibraryImportPhase, retryingAutomatically: Bool = false) -> Bool {
        switch self {
        case .all: true
        case .failed: (phase == .failed && !retryingAutomatically) || phase == .membershipConflict
        case .unread, .reading, .archived: false
        }
    }

    /// An Add still waiting to sync shows only under All.
    var includesQueued: Bool { self == .all }
}

/// What the filter row offers: rows per quick filter and the tags within the current one.
struct LibraryFilterSummary: Equatable {
    var counts: [LibraryFilter: Int] = [:]
    var tags: [(tag: String, count: Int)] = []

    func count(_ filter: LibraryFilter) -> Int { counts[filter] ?? 0 }

    /// The quick filters worth offering: All, then each one that would show something different from All (or is
    /// chosen). Empty when nothing narrows the list (a new library), so the filter row stays hidden.
    func chips(selected: LibraryFilter, tagSelected: Bool) -> [LibraryFilter] {
        func differs(_ filter: LibraryFilter) -> Bool {
            switch filter {
            case .all: false
            case .archived: count(filter) > 0                                      // never part of All
            case .unread, .reading, .failed: count(filter) > 0 && count(filter) < count(.all)
            }
        }
        let shown = LibraryFilter.allCases.filter { $0 == .all || $0 == selected || differs($0) }
        return shown.count > 1 || showsTags(tagSelected: tagSelected) ? shown : []
    }

    /// The Tags menu is offered when there are tags to choose between.
    func showsTags(tagSelected: Bool) -> Bool { tagSelected || tags.count > 1 }

    static func == (a: Self, b: Self) -> Bool {
        a.counts == b.counts && a.tags.map(\.tag) == b.tags.map(\.tag) && a.tags.map(\.count) == b.tags.map(\.count)
    }
}

/// Which Library table columns are turned on, kept per device and separately for compact (iPhone) and regular
/// (iPad, Mac) widths (owner request 2026-10-07: "columns that can be turned on or off"). Title is always shown.
struct LibraryColumnSettings: Equatable, Sendable {
    enum WidthClass: String, CaseIterable, Sendable {
        case compact, regular
        var title: String { self == .compact ? "iPhone" : "iPad and Mac" }
    }

    static let defaultsKeyPrefix = "library.columns."
    /// Phone: Year and Progress in portrait; landscape adds the dates and chats where they fit.
    static let compactDefault: Set<LibraryTableColumn> = [.year, .added, .opened, .chats, .progress]
    static let regularDefault: Set<LibraryTableColumn> = [.year, .tags, .added, .opened, .chats, .progress]

    var compact = Self.compactDefault
    var regular = Self.regularDefault

    static func defaultColumns(_ width: WidthClass) -> Set<LibraryTableColumn> { width == .compact ? compactDefault : regularDefault }

    subscript(width: WidthClass) -> Set<LibraryTableColumn> {
        get { width == .compact ? compact : regular }
        set { if width == .compact { compact = newValue } else { regular = newValue } }
    }

    /// Unknown names (a column a later build removed) are ignored; a missing key means the defaults.
    static func load(from defaults: UserDefaults) -> Self {
        var settings = Self()
        for width in WidthClass.allCases {
            guard let saved = defaults.string(forKey: defaultsKeyPrefix + width.rawValue) else { continue }
            settings[width] = Set(saved.split(separator: ",").compactMap { LibraryTableColumn(rawValue: String($0)) })
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        for width in WidthClass.allCases {
            let names = LibraryTableColumn.allCases.filter(self[width].contains).map(\.rawValue)
            defaults.set(names.joined(separator: ","), forKey: Self.defaultsKeyPrefix + width.rawValue)
        }
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

    /// One author → the full name; two or three → family names; more → three family names and "+N". The browser's
    /// `compactAuthors` applies the same rule, so rows and columns read alike on every surface.
    static func shortAuthors(_ names: [String]) -> String? {
        let authors = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = authors.first else { return nil }
        if authors.count == 1 { return first }
        let shown = authors.prefix(3).map(familyName).joined(separator: ", ")
        return authors.count > 3 ? "\(shown) +\(authors.count - 3)" : shown
    }

    /// Full names, `limit` at most, then "+N": cards with room (an expanded feed row, a podcast episode, the player's
    /// "Paper by" line). The browser's `authorLine` is the same.
    static func authorLine(_ names: [String], limit: Int = 6) -> String? {
        let authors = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !authors.isEmpty else { return nil }
        let shown = authors.prefix(limit).joined(separator: ", ")
        return authors.count > limit ? "\(shown) +\(authors.count - limit)" : shown
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

/// The step an import in progress is on, in the reader's words (owner, 2026-10-07: "What does 'Converting...'
/// mean? What is a reader to the user?"). `converting` is the server's OCR (reading equations and figures) and
/// `building` its rendering (preparing it for reading); `preparing` is an import whose step an older server
/// didn't say.
enum LibraryImportStep: Equatable, Sendable {
    case queued, finding, preparing, downloading, converting, building
    /// Paused on the server's side (e.g. the conversion budget); it carries on by itself.
    case waiting

    /// The list's name for the step.
    var title: String {
        switch self {
        // One word for the server's stage (owner, build 44: "what you mean… is really Adding to library"): the device's
        // own download and preparation say "Downloading…" and "Preparing…" afterwards.
        case .downloading: "Downloading…"
        case .queued, .finding, .preparing, .converting, .building, .waiting: "Adding…"
        }
    }
    /// Short enough for a table column.
    var shortTitle: String {
        switch self {
        case .downloading: "Downloading…"; default: "Adding…"
        }
    }
    /// One word, beside a spinner in the table's Progress column.
    var tableTitle: String {
        switch self {
        case .downloading: "Downloading"; default: "Adding"
        }
    }
    /// "Downloading…" or "Preparing…", the same in both widths.
    func label(short: Bool) -> String {
        short ? shortTitle : title
    }
    /// The status line with how long the step has run: "Downloading… · 1 min", then past three minutes
    /// "Downloading… · Taking longer than usual". In the first minute, the plain label.
    func status(short: Bool, elapsed: ImportStepElapsed?) -> String {
        guard let suffix = elapsed?.label else { return label(short: short) }
        return (short ? shortTitle : title) + " · " + suffix
    }
    /// What VoiceOver reads: "Downloading, 4 minutes, taking longer than usual" (no ellipsis spoken).
    func spokenStatus(elapsed: ImportStepElapsed?) -> String {
        guard let time = elapsed?.spokenLabel else { return tableTitle }
        return tableTitle + ", " + time
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
    /// Source-only imports are deliberately a link/device path. Name the
    /// arXiv action directly so a reader does not mistake it for a server PDF.
    var sourceLinkTitle: String { source == "arxiv" ? "Open on arXiv" : "View source" }

    /// The step while the import is in progress: the server's detailed step (migration 029), else its coarse
    /// progress (an import can still read "accepted" while its paper is already converting), else its phase.
    var step: LibraryImportStep? {
        switch phase {
        case .accepted, .resolving, .acquiring:
            switch progressDetail?.step {
            case .finding: return .finding
            case .downloading: return .downloading
            case .readingEquations: return .converting
            case .preparing: return .building
            case .waiting: return .waiting
            case .other, nil: break
            }
            return switch progress {
            case .finding: .finding
            case .downloading: .downloading
            case .converting: .converting
            case .rendering, .finishing: .building
            default: phase == .accepted ? .queued : phase == .resolving ? .finding : .preparing
            }
        default: return nil
        }
    }
    /// The list's full status line. Failures say what failed in plain words.
    var libraryStatus: String {
        switch phase {
        case .accepted, .resolving, .acquiring: return step?.label(short: false) ?? "Waiting to start"
        case .sourceOnly: return source == "arxiv" ? "Available on arXiv" : "Available at source"
        case .failed:
            switch errorCode {
            case .insufficientCredits: return "Not enough credits to convert this paper"
            case .tooLarge: return "This PDF is too large to convert"
            case .pdfInvalid: return "This PDF couldn’t be read"
            case .conversionFailed: return "Conversion failed"
            case .downloadFailed, .rateLimited: return "Couldn’t download this paper"
            case .downloadRetrying: return "Couldn’t download yet · Trying again automatically"
            case .pdfRestricted: return "This PDF needs a sign-in or subscription"
            case .sourceBlocked: return "The paper’s website blocked the download"
            case .sourceUnavailable: return "The paper’s website isn’t responding"
            case .notPDF: return "The paper’s link doesn’t lead to a PDF"
            case .notOpen: return "This paper isn’t openly available"
            case .uploadFailed: return "The uploaded PDF didn’t arrive intact"
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
        case .accepted, .resolving, .acquiring: return step?.label(short: true) ?? "Waiting"
        case .failed:
            switch errorCode {
            case .insufficientCredits: return "Needs credits"
            case .tooLarge: return "Too large to convert"
            case .pdfInvalid: return "PDF unreadable"
            case .conversionFailed: return "Conversion failed"
            case .downloadFailed, .rateLimited: return "Download failed"
            case .downloadRetrying: return "Retrying soon"
            case .pdfRestricted: return "Sign-in required"
            case .sourceBlocked: return "Download blocked"
            case .sourceUnavailable: return "Site not responding"
            case .notPDF: return "No PDF at link"
            case .notOpen: return "Not openly available"
            case .uploadFailed: return "Upload incomplete"
            case .metadataUnavailable: return "Details unavailable"
            case .licenseUnverified: return "License unconfirmed"
            default: return "Import failed"
            }
        default: return libraryStatus
        }
    }
    var isActive: Bool { [.resolving, .acquiring].contains(phase) }
    /// The step a retry starts again from, shown as soon as Retry is tapped: downloading again when the paper's
    /// details are known (the server resumes it as acquiring), else finding it.
    var retryStep: LibraryImportStep { errorCode == .downloadRetrying || metadataID != nil ? .downloading : .finding }
}

/// Everything the Table shows for one library entry.
/// What of a paper this device holds. Reading, chat, Study and Listen all work from the paper's structured text on
/// this device; a paper that is only in the synced library opens from arXiv when the network allows, and a PDF kept
/// on the device is read as a PDF (no structured text).
enum PaperDeviceCopy: Equatable, Sendable {
    /// Prepared on this device: reads offline; chat, Study and Listen have its text.
    case reader
    /// A PDF file on this device: reads as a PDF; no structured text for chat, Study or Listen.
    case pdf
    /// In the library, not on this device yet: opens from arXiv (or the server's copy) when online.
    case cloud
    /// No readable copy can be made here (not converted, quarantined, or source unavailable).
    case unavailable

    var symbol: String {
        switch self {
        // Two symbols (owner, build 42: "either it's there… or the cloud icon"): a check for a copy that opens at
        // once (prepared, or a PDF), the cloud for one still to download.
        case .reader, .pdf: "checkmark.circle.fill"; case .cloud: "icloud.and.arrow.down"; case .unavailable: "exclamationmark.circle"
        }
    }
    /// VoiceOver, and the row's tooltip on the Mac.
    var label: String {
        switch self {
        case .reader: "On this device"; case .pdf: "PDF on this device"; case .cloud: "Not on this device yet; tap to download"
        case .unavailable: "No readable copy on this device"
        }
    }
}

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
    /// Display names (`LibraryTags`): the paper's own tags, else topics from its categories.
    let tags: [String]
    let added: Date?
    let opened: Date?
    let progress: Double?
    let chats: Int
    let pages: Int?
    let status: Status
    let needsCredits: Bool
    /// An import in progress: its step and when this device first saw it there.
    var stepTiming: ImportStepTiming? = nil
    /// An import in progress: its percent, time left and step words (`ImportProgressView` draws it).
    var importProgress: ImportProgress? = nil
    /// The arXiv identifier, or a web paper's host.
    var source: String? = nil
    var spokenSource: String? = nil
    /// An import in progress, or one being retried: the step it is on.
    var step: LibraryImportStep? = nil
    /// What a stopped import offers beside its status (owner feedback 2026-10-07: a failed import should never just
    /// sit there).
    var importAction: LibraryImportAction? = nil
    /// Whether this device holds the paper (owner request 2026-10-14: "make it more obvious whether you do or do not
    /// have a pdf on a device"); nil for an import.
    var deviceCopy: PaperDeviceCopy? = nil

    var statusText: String? {
        switch status { case .none: nil; case .active(let text), .info(let text), .problem(let text): text }
    }
}

/// The one action a stopped import shows inline, beside its status.
enum LibraryImportAction: Equatable, Sendable {
    /// The server can run it again (download or details failed).
    case retry
    /// Conversion is waiting for credits.
    case getCredits
    /// Nothing can be retried (too large, unreadable PDF…): take it off the list.
    case remove
    /// No open copy, or the reader's upload didn't arrive: the reader supplies the PDF from Files.
    case uploadPDF
    /// The website refused our servers: this device fetches the PDF and uploads it to the same paper.
    case downloadOnDevice
    /// A source-only PDF already encrypted on this device can be read locally.
    case openLocalPDF

    var title: String {
        switch self {
        case .retry: "Retry"; case .getCredits: "Get credits"; case .remove: "Remove"; case .uploadPDF: "Upload PDF"
        case .downloadOnDevice: "Download on this device"
        case .openLocalPDF: "Open PDF"
        }
    }

    /// Nil while the import is running, or while a retry is on its way.
    static func available(for item: LibraryImportRecord, retrying: Bool, localPaperAvailable: Bool = false) -> Self? {
        // The server trying again by itself (`download_retrying`) is under way, not a failure.
        guard !retrying, !item.isRetryingAutomatically else { return nil }
        switch item.phase {
        case .sourceOnly:
            // Default-license arXiv papers stay source-only on the server. A
            // device may keep its own encrypted copy without creating a cloud
            // import or OCR job.
            guard item.source == "arxiv", item.sourceURL != nil else { return nil }
            return localPaperAvailable ? .openLocalPDF : .downloadOnDevice
        case .failed:
            if item.errorCode == .insufficientCredits { return .getCredits }
            if item.canTakeUpload, [.notOpen, .uploadFailed].contains(item.errorCode) { return .uploadPDF }
            if item.canDownloadOnDevice, [.sourceBlocked, .pdfRestricted].contains(item.errorCode) { return .downloadOnDevice }
            return item.retryable ? .retry : .remove
        case .membershipConflict: return .remove
        default: return nil
        }
    }
}
