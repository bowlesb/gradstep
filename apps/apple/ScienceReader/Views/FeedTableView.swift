import SwiftUI
import ScienceReaderCore

/// What the Feed table sorts by. Suggested is the server's order (For you's ranking); it has no column.
enum FeedSortKey: Hashable, CaseIterable {
    case suggested, published, popularity, title, topic, authors
    var label: String {
        switch self {
        case .suggested: "Suggested"; case .published: "Published"; case .popularity: "Popularity"; case .title: "Title"
        case .topic: "Topics"; case .authors: "Authors"
        }
    }
    var ascendingFirst: Bool { ![.published, .popularity, .suggested].contains(self) }
    /// The orders offered for a selection: Suggested only where the server ranks (For you and topics).
    static func offered(personal: Bool) -> [FeedSortKey] { allCases.filter { personal || $0 != .suggested } }
}

/// The Feed's columns: Title (and first author) always, the reader's choice of Popularity, Topics, Published, Authors,
/// arXiv ID and Abstract (owner feedback, build 17: "why are there so few options"; build 21: "Why not topics? And can we
/// put a popularity score?"), and Add, which stays at the trailing end. When the chosen columns don't fit, they scroll
/// sideways under the pinned title (`TableArrangement`).
enum FeedTableColumn: String, CaseIterable, Identifiable, Sendable {
    // "topic" keeps its stored name so readers' saved choices carry over to Topics.
    case popularity, topic, published, authors, arxiv, abstract, add

    typealias Column = PaperTableColumn<FeedSortKey>
    static let title = Column(id: "title", title: "Title", sortKey: .title, ascendingFirst: true)
    var id: String { rawValue }

    /// The columns the reader chooses (Add always shows).
    static let choosable: [FeedTableColumn] = [.popularity, .topic, .published, .authors, .arxiv, .abstract]
    /// iPhone: Popularity beside the title in portrait, Topics and Published scroll in; iPad and Mac add the authors.
    static let compactDefault: Set<FeedTableColumn> = [.popularity, .topic, .published]
    static let regularDefault: Set<FeedTableColumn> = [.popularity, .topic, .published, .authors]
    /// Columns added after readers had saved choices: shown once to those readers if they are a default.
    static let introduced: Set<FeedTableColumn> = [.popularity]

    var title: String {
        switch self {
        case .popularity: "Popularity"; case .topic: "Topics"; case .published: "Published"; case .authors: "Authors"; case .arxiv: "arXiv ID"
        case .abstract: "Abstract"; case .add: ""
        }
    }

    var explanation: String {
        switch self {
        case .popularity: "Upvotes on Hugging Face Papers"
        case .topic: "Its specific topics, from title and abstract"
        case .published: "Month it appeared on arXiv"
        case .authors: "The first authors"
        case .arxiv: "Its arXiv identifier"
        case .abstract: "The abstract's first lines"
        case .add: "Add to your library"
        }
    }

    var column: Column {
        switch self {
        case .popularity: Column(id: rawValue, title: title, priority: 1, width: 84, sortKey: .popularity)
        case .topic: Column(id: rawValue, title: title, priority: 2, width: 170, sortKey: .topic, ascendingFirst: true)
        case .published: Column(id: rawValue, title: title, priority: 3, width: 88, sortKey: .published)
        case .authors: Column(id: rawValue, title: title, priority: 4, width: 140, sortKey: .authors, ascendingFirst: true)
        case .arxiv: Column(id: rawValue, title: title, priority: 5, width: 92)
        case .abstract: Column(id: rawValue, title: title, priority: 6, width: 260)
        case .add: Column(id: rawValue, title: "", priority: 0, width: 56, alignment: .trailing, isControl: true)
        }
    }

    /// Every column, in row order.
    static let all: [Column] = allCases.map(\.column)
    /// The chosen columns and Add, in row order.
    static func columns(_ enabled: Set<FeedTableColumn>) -> [Column] { allCases.filter { $0 == .add || enabled.contains($0) }.map(\.column) }

    /// Newest first, like the List.
    static let defaultSort = PaperTableSort(key: FeedSortKey.published, ascending: false)
    /// For you and topics: the server's ranking.
    static let suggestedSort = PaperTableSort(key: FeedSortKey.suggested, ascending: false)
    static func defaultSort(personal: Bool) -> PaperTableSort<FeedSortKey> { personal ? suggestedSort : defaultSort }
}

/// Feed values derived from what the server sends (title, authors, year, categories, the arXiv identifier).
enum FeedFormat {
    /// The submission month an arXiv identifier carries ("2610.01234" → October 2026; "hep-th/9901001" → January
    /// 1999), with its sequence number for ordering within the month. Nil for anything else.
    static func arxivMonth(_ sourceID: String) -> (year: Int, month: Int, number: Int)? {
        let id = sourceID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        let digits: Substring
        if let slash = id.lastIndex(of: "/") { digits = id[id.index(after: slash)...] }   // old style: archive/YYMMNNN
        else if let dot = id.firstIndex(of: ".") { digits = id[..<dot] + id[id.index(after: dot)...] } // new: YYMM.NNNNN
        else { return nil }
        guard digits.count >= 7, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let yy = Int(digits.prefix(2)), let month = Int(digits.dropFirst(2).prefix(2)), (1...12).contains(month),
              let number = Int(digits.dropFirst(4)) else { return nil }
        return (yy >= 91 ? 1900 + yy : 2000 + yy, month, number)
    }

    /// "Oct 2026" from the identifier; else the year.
    static func published(_ result: DiscoveryResult, calendar: Calendar = .current) -> String? {
        guard let month = arxivMonth(result.sourceID),
              let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 15)) else {
            return result.year.map(String.init)
        }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style.month(.abbreviated).year())
    }

    /// "October 2026", for VoiceOver.
    static func spokenPublished(_ result: DiscoveryResult, calendar: Calendar = .current) -> String? {
        guard let month = arxivMonth(result.sourceID),
              let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 15)) else {
            return result.year.map { "Published \($0)" }
        }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return "Published " + date.formatted(style.month(.wide).year())
    }

    /// The paper's specific topics from the server (most specific first); from an older server, its arXiv categories'
    /// friendly names.
    static func topics(_ result: DiscoveryResult, limit: Int = 3) -> [String] {
        result.topics.isEmpty ? ArxivTopics.names(for: result.categories, limit: min(limit, 2)) : Array(result.topics.prefix(limit))
    }

    /// The paper's first topic (Topics sorts by it).
    static func topic(_ result: DiscoveryResult) -> String? { topics(result, limit: 1).first }

    /// "▲ 162": upvotes on Hugging Face Papers; nil when unknown (the table shows a dash, never a made-up zero).
    static func popularity(_ result: DiscoveryResult) -> String? { result.upvotes.map { "▲ \($0)" } }

    static func spokenPopularity(_ result: DiscoveryResult) -> String {
        guard let votes = result.upvotes else { return "Popularity unknown" }
        return votes == 1 ? "1 upvote on Hugging Face Papers" : "\(votes) upvotes on Hugging Face Papers"
    }

    /// The title cell's second line: why For you suggests it, then the first author.
    static func subtitle(_ result: DiscoveryResult) -> String? {
        let parts = [result.reason?.text, LibraryFormat.firstAuthor(result.authors)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The results in the chosen order; ties (and unknown values, which go last) keep the server's order.
    static func ordered(_ results: [DiscoveryResult], by sort: PaperTableSort<FeedSortKey>) -> [DiscoveryResult] {
        let indexed = Array(results.enumerated())
        func before(_ a: (offset: Int, element: DiscoveryResult), _ b: (offset: Int, element: DiscoveryResult)) -> Bool {
            switch sort.key {
            case .suggested:
                break
            case .popularity:
                switch (a.element.upvotes, b.element.upvotes) {
                case let (x?, y?) where x != y: return sort.ascending ? x < y : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .title:
                let order = a.element.title.localizedStandardCompare(b.element.title)
                if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
            case .published:
                let x = arxivMonth(a.element.sourceID).map { ($0.year * 100 + $0.month, $0.number) }
                    ?? a.element.year.map { ($0 * 100, 0) }
                let y = arxivMonth(b.element.sourceID).map { ($0.year * 100 + $0.month, $0.number) }
                    ?? b.element.year.map { ($0 * 100, 0) }
                switch (x, y) {
                case let (x?, y?) where x != y: return sort.ascending ? x < y : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .authors:
                let x = a.element.authors.first.map(LibraryFormat.familyName), y = b.element.authors.first.map(LibraryFormat.familyName)
                switch (x, y) {
                case let (x?, y?):
                    let order = x.localizedStandardCompare(y)
                    if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .topic:
                switch (topic(a.element), topic(b.element)) {
                case let (x?, y?):
                    let order = x.localizedStandardCompare(y)
                    if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return a.offset < b.offset
        }
        return indexed.sorted(by: before).map(\.element)
    }
}

/// The Feed as a table: the same `PaperTable` as the Library. Tapping a row shows its abstract under it; Add stays
/// in its own column; long-press offers Add and View on arXiv.
struct FeedTable: View {
    @Bindable var model: ReaderModel
    @Binding var issue: String?
    @State private var expanded: Set<String> = []
    @State private var adding: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Suggested (the server's ranking) shows no sort indicator: it is the list as served.
        PaperTable(rows: FeedFormat.ordered(model.shownFeedResults, by: model.feedSort), titleColumn: FeedTableColumn.title,
                   columns: FeedTableColumn.columns(model.feedColumns[.current]), sort: $model.feedSort,
                   extraSortTitles: Dictionary(uniqueKeysWithValues: FeedSortKey.allCases.filter { $0 != .suggested }.map { ($0, $0.label) }),
                   horizontalScroll: true,
                   identifier: "feed.table",
                   rowIdentifier: { "feed.table.\($0.sourceID)" },
                   title: { PaperTableTitle(title: $0.title, subtitle: FeedFormat.subtitle($0), expanded: expanded.contains($0.id),
                                            subtitleLines: $0.reason == nil ? 1 : 2) },
                   cell: { result, column in cell(result, column: FeedTableColumn(rawValue: column)) },
                   spoken: { result, column in spoken(result, column: FeedTableColumn(rawValue: column)) },
                   primaryAction: { action(for: $0) },
                   menu: { result in actions(result) },
                   swipe: { _ in EmptyView() },
                   detail: { result, _ in
                       if expanded.contains(result.id), let abstract = result.abstract {
                           Text(abstract).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                               .frame(maxWidth: .infinity, alignment: .leading)
                           if result.abstractTruncated, let url = URL(string: "https://arxiv.org/abs/\(result.sourceID)") {
                               Link("Read the full abstract on arXiv", destination: url).font(.footnote)
                           }
                       }
                   },
                   top: {
                       if let issue {
                           StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue).listRowSeparator(.hidden)
                       }
                       FeedColdStartNote(model: model)
                   })
    }

    @ViewBuilder private func cell(_ result: DiscoveryResult, column: FeedTableColumn?) -> some View {
        switch column {
        case .popularity:
            Text(FeedFormat.popularity(result) ?? "—").font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        case .topic: PaperTableChips(tags: FeedFormat.topics(result))
        case .published: PaperTableText(text: FeedFormat.published(result))
        case .authors: Text(LibraryFormat.shortAuthors(result.authors) ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        case .arxiv: PaperTableText(text: result.sourceID)
        case .abstract: Text(result.abstract ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
        case .add:
            DiscoveryAddControl(sourceID: result.sourceID, inLibrary: model.librarySourceIDs.contains(result.sourceID),
                                adding: adding.contains(result.id), enabled: model.canBeginImport,
                                preparing: model.devicePreparation(sourceID: result.sourceID),
                                open: { model.openLibraryPaper(sourceID: result.sourceID) }) { add(result) }
        case nil: EmptyView()
        }
    }

    private func spoken(_ result: DiscoveryResult, column: FeedTableColumn?) -> String? {
        switch column {
        case .popularity: FeedFormat.spokenPopularity(result)
        case .topic: FeedFormat.topics(result).joined(separator: ", ")
        case .published: FeedFormat.spokenPublished(result)
        case .authors: LibraryFormat.shortAuthors(result.authors).map { "By \($0)" }
        case .arxiv: "arXiv \(result.sourceID)"
        case .abstract: nil   // the row's tap shows it in full
        case .add, nil: nil   // a control: the Add button (or "In library") is its own element
        }
    }

    private func action(for result: DiscoveryResult) -> PaperTableAction? {
        guard result.abstract != nil else { return nil }
        let open = expanded.contains(result.id)
        return PaperTableAction(hint: open ? "Hides the abstract" : "Shows the abstract") {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                if open { expanded.remove(result.id) } else { expanded.insert(result.id) }
            }
        }
    }

    @ViewBuilder private func actions(_ result: DiscoveryResult) -> some View {
        if !model.librarySourceIDs.contains(result.sourceID) {
            Button("Add to library", systemImage: "plus") { add(result) }.disabled(!model.canBeginImport || adding.contains(result.id))
        }
        if let url = URL(string: "https://arxiv.org/abs/\(result.sourceID)") {
            Link(destination: url) { Label("View on arXiv", systemImage: "safari") }
        }
    }

    private func add(_ result: DiscoveryResult) {
        adding.insert(result.id); issue = nil
        Task {
            do { try await model.addDiscovered(result) }
            catch { issue = "Couldn’t add “\(result.title)”. Try again." }
            adding.remove(result.id)
        }
    }
}

/// Add, a spinner while adding, or a checkmark once the paper is in the library (Feed list and table, arXiv search).
struct DiscoveryAddControl: View {
    let sourceID: String
    let inLibrary: Bool
    let adding: Bool
    let enabled: Bool
    /// Preparing on this device right after the add (fraction): a small bar and percent instead of the checkmark.
    var preparing: Double? = nil
    /// The checkmark opens the paper (owner, build 42: "it should take me to the library entry for that item").
    var open: (() -> Void)? = nil
    let add: () -> Void
    var body: some View {
        if let preparing {
            VStack(spacing: 3) {
                ProgressView(value: preparing).frame(width: 40)
                Text("\(Int((preparing * 100).rounded(.down)))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ArxivHTMLReader.phase(for: preparing)) \(Int((preparing * 100).rounded(.down))) percent")
        } else if inLibrary, let open {
            Button(action: open) { Image(systemName: "checkmark").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.plain).accessibilityLabel("In library").accessibilityHint("Opens the paper")
        } else if inLibrary {
            Image(systemName: "checkmark").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44).accessibilityLabel("In library")
        } else if adding {
            ProgressView().frame(minWidth: 44, minHeight: 44)
        } else {
            // Enabled: an accent capsule; unavailable: neutral gray with the system's disabled treatment. Avoid a
            // second opacity reduction, which makes the label almost disappear in light mode.
            Button("Add", action: add)
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                .tint(enabled ? Color.accentColor : Color.gray)
                .disabled(!enabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("discover.add.\(sourceID)")
        }
    }
}

// MARK: For you and topics (docs/architecture/PERSONALIZED_FEED.md)

/// The Feed header's chips. With For you: For you first, the reader's specific topics in the order the server chose
/// (most interesting first), a category picked from More topics while it is shown, and More topics (the broad arXiv
/// categories). Without For you: the library's categories, exactly as before.
struct FeedChipsBar: View {
    @Bindable var model: ReaderModel

    var body: some View {
        let selected = model.currentFeedSelection
        HStack(spacing: 8) {
            ForEach(FeedChips.chips(personal: model.feedPersonal, categories: model.feedCategories, selected: selected)) { chip in
                ChipButton(title: chip.title, selected: chip.selection == selected) { model.selectFeed(chip.selection) }
                    .accessibilityIdentifier(chip.id)
            }
            if model.feedPersonal.available != false { moreTopics(selected) }
        }
    }

    private func moreTopics(_ selected: FeedSelection) -> some View {
        Menu {
            Section("arXiv categories") {
                ForEach(FeedChips.moreTopics(categories: model.feedCategories), id: \.self) { category in
                    Button { model.selectFeed(.category(category)) } label: {
                        if selected == .category(category) { Label(ArxivTopics.name(for: category), systemImage: "checkmark") }
                        else { Text(ArxivTopics.name(for: category)) }
                    }
                    .accessibilityIdentifier("feed.more.\(category)")
                }
            }
        } label: {
            ChipLabel(title: "More topics", selected: false, systemImage: "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More topics")
        .accessibilityHint("Broad arXiv categories")
        .accessibilityIdentifier("feed.moreTopics")
    }
}

/// Why For you suggests a paper, under its authors: "In your tag: RLHF".
struct FeedReasonLine: View {
    let reason: FeedReason
    var body: some View {
        Label {
            Text(reason.text).lineLimit(2)
        } icon: {
            Image(systemName: reason.kind == "trending" ? "arrow.up.right" : "sparkles").imageScale(.small)
        }
        .font(.footnote).foregroundStyle(Color.accentColor)
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Why: \(reason.text)")
    }
}

/// For you with nothing to go on yet: one line saying how it learns.
struct FeedColdStartNote: View {
    @Bindable var model: ReaderModel
    var body: some View {
        if model.feedShown == .forYou && model.feedPersonal.coldStart {
            Text("For you learns from the papers you add and the tags you give them.")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("feed.coldStart")
        }
    }
}
