import SwiftUI
import ScienceReaderCore

/// What the Feed table sorts by.
enum FeedSortKey: Hashable { case title, published, topic }

/// The Feed's columns: Title (and first author), Topic, Published, and Add. Phone portrait has room for the title,
/// Published and Add; wider screens add the topic.
enum FeedTableColumn: String {
    case topic, published, add

    typealias Column = PaperTableColumn<FeedSortKey>
    static let title = Column(id: "title", title: "Title", sortKey: .title, ascendingFirst: true)
    static let all: [Column] = [
        Column(id: topic.rawValue, title: "Topic", priority: 2, width: 130, sortKey: .topic, ascendingFirst: true),
        Column(id: published.rawValue, title: "Published", priority: 1, width: 88, sortKey: .published),
        Column(id: add.rawValue, title: "", priority: 0, width: 56, alignment: .trailing, isControl: true),
    ]
    /// Newest first, like the List.
    static let defaultSort = PaperTableSort(key: FeedSortKey.published, ascending: false)
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

    /// The paper's main topic, by its friendly name.
    static func topic(_ result: DiscoveryResult) -> String? { ArxivTopics.names(for: result.categories, limit: 1).first }

    /// The results in the chosen order; ties (and unknown values, which go last) keep the server's order.
    static func ordered(_ results: [DiscoveryResult], by sort: PaperTableSort<FeedSortKey>) -> [DiscoveryResult] {
        let indexed = Array(results.enumerated())
        func before(_ a: (offset: Int, element: DiscoveryResult), _ b: (offset: Int, element: DiscoveryResult)) -> Bool {
            switch sort.key {
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
        PaperTable(rows: FeedFormat.ordered(model.feedResults, by: model.feedSort), titleColumn: FeedTableColumn.title,
                   columns: FeedTableColumn.all, sort: $model.feedSort, identifier: "feed.table",
                   rowIdentifier: { "feed.table.\($0.sourceID)" },
                   title: { PaperTableTitle(title: $0.title, subtitle: LibraryFormat.firstAuthor($0.authors)) },
                   cell: { result, column in cell(result, column: FeedTableColumn(rawValue: column)) },
                   spoken: { result, column in spoken(result, column: FeedTableColumn(rawValue: column)) },
                   primaryAction: { action(for: $0) },
                   menu: { result in actions(result) },
                   swipe: { _ in EmptyView() },
                   detail: { result in
                       if expanded.contains(result.id), let abstract = result.abstract {
                           Text(abstract).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                               .frame(maxWidth: .infinity, alignment: .leading)
                       }
                   },
                   top: {
                       if let issue {
                           StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue).listRowSeparator(.hidden)
                       }
                   })
    }

    @ViewBuilder private func cell(_ result: DiscoveryResult, column: FeedTableColumn?) -> some View {
        switch column {
        case .topic: Text(FeedFormat.topic(result) ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        case .published: PaperTableText(text: FeedFormat.published(result))
        case .add:
            DiscoveryAddControl(sourceID: result.sourceID, inLibrary: model.librarySourceIDs.contains(result.sourceID),
                                adding: adding.contains(result.id), enabled: model.canBeginImport) { add(result) }
        case nil: EmptyView()
        }
    }

    private func spoken(_ result: DiscoveryResult, column: FeedTableColumn?) -> String? {
        switch column {
        case .topic: ArxivTopics.names(for: result.categories, limit: 2).joined(separator: ", ")
        case .published: FeedFormat.spokenPublished(result)
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
    let add: () -> Void
    var body: some View {
        if inLibrary {
            Image(systemName: "checkmark").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44).accessibilityLabel("In library")
        } else if adding {
            ProgressView().frame(minWidth: 44, minHeight: 44)
        } else {
            Button("Add", action: add)
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(!enabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("discover.add.\(sourceID)")
        }
    }
}
