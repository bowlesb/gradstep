import CoreGraphics
import Foundation
import ScienceReaderCore

/// Library layout (owner decision 2026-10-05): the List stays the default. "Table" is a sortable
/// native table in wide containers and renders as detailed rows in narrow ones.
enum LibraryLayout: String, CaseIterable, Sendable {
    case list, table

    /// Below this container width (iPhone portrait, the iPad Browse column, narrow split view) or
    /// at accessibility text sizes, "Table" shows detailed rows instead.
    /// The native iPad table needs its columns' width (design audit F1: at 834 pt titles and
    /// status were clipped); narrower iPad containers show detailed rows.
    static let tableMinimumWidth: CGFloat = 980
    /// The app-drawn iPhone landscape table is narrower.
    static let compactTableMinimumWidth: CGFloat = 700
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
}

extension LibraryImportRecord {
    /// The server's progress when known, in any active phase (an import can still
    /// read "accepted" while its paper is already converting).
    private var progressLabel: String? {
        switch progress {
        case .finding: "Finding paper…"
        case .downloading: "Downloading PDF…"
        case .converting: "Converting equations and figures…"
        case .rendering, .finishing: "Building reader…"
        default: nil
        }
    }
    /// The list's full status line.
    var libraryStatus: String {
        switch phase {
        case .accepted: progressLabel ?? "Queued"
        case .resolving: progressLabel ?? "Finding paper…"
        case .acquiring: progressLabel ?? "Preparing PDF…"
        case .sourceOnly: "Available at source"
        case .failed:
            switch errorCode {
            case .insufficientCredits: "Not enough credits to convert this paper"
            case .tooLarge: "This PDF is too large to convert"
            case .pdfInvalid: "This PDF couldn’t be read"
            case .conversionFailed: "Conversion failed"
            case .downloadFailed, .rateLimited: "Couldn’t download this paper"
            default: "Couldn’t import this paper"
            }
        case .membershipConflict: "Not added to library"
        case .ready: "Added"
        case .cancelled: "Cancelled"
        }
    }
    /// The same status, short enough for a table column.
    var libraryShortStatus: String {
        switch phase {
        case .accepted, .resolving, .acquiring:
            switch progress {
            case .converting: "Converting…"
            case .rendering, .finishing: "Building reader…"
            case .downloading: "Downloading…"
            case .finding: "Finding paper…"
            default: phase == .accepted ? "Queued" : phase == .resolving ? "Finding paper…" : "Preparing PDF…"
            }
        case .failed:
            switch errorCode {
            case .insufficientCredits: "Needs credits"
            case .tooLarge: "Too large to convert"
            case .pdfInvalid: "PDF unreadable"
            case .conversionFailed: "Conversion failed"
            case .downloadFailed, .rateLimited: "Download failed"
            default: "Import failed"
            }
        default: libraryStatus
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
