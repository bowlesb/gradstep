import CryptoKit
import Foundation

/// What global search finds besides papers (docs/architecture/GLOBAL_SEARCH.md). Each is one document of the account's
/// `everything-index` (the Library's papers stay in `search-index`).
public enum SearchItemKind: String, CaseIterable, Sendable, Codable {
    case conversation, message, diagram, equation, figure, paperExplainer = "paper", collection, snippet

    public var group: SearchGroup {
        switch self {
        case .conversation, .message: .chats
        case .equation, .figure, .paperExplainer: .explanations
        case .collection, .snippet: .snippets
        case .diagram: .diagrams
        }
    }
}

/// The groups of the search screen, in the order they show (proposal B.4: a fixed order, so rows never jump between
/// groups as you type). `passages` is the "In this paper" scope's first group.
public enum SearchGroup: String, CaseIterable, Sendable, Codable, Comparable {
    case passages, papers, chats, explanations, snippets, diagrams, feed, tags, settings

    public var title: String {
        switch self {
        case .passages: "Passages"; case .papers: "Papers"; case .chats: "Chats"; case .explanations: "Explanations"
        case .snippets: "Snippets"; case .diagrams: "Diagrams"; case .feed: "Feed"; case .tags: "Tags"; case .settings: "Settings"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// What the index keeps beside an item's words (sealed in its manifest): enough to group, scope and rank a hit, and to
/// find its source again, without reading the source.
public struct SearchItemInfo: Equatable, Sendable {
    public let kind: SearchItemKind
    /// The item's own identifier: an entity or event ID, or a kept explanation's file name.
    public let id: String
    /// The library paper it is about (a paper chat's paper, an explanation's, a snippet's source).
    public var paperID: UUID?
    /// A message's conversation, a snippet's collection.
    public var container: UUID?
    /// When it was last used or saved (recency).
    public var date: Date?
    /// A question the reader asked (their own words rank above an answer's).
    public var byReader: Bool

    public init(kind: SearchItemKind, id: String, paperID: UUID? = nil, container: UUID? = nil, date: Date? = nil, byReader: Bool = false) {
        self.kind = kind; self.id = id; self.paperID = paperID; self.container = container; self.date = date; self.byReader = byReader
    }

    /// The conversation or collection a row collapses into (a message's or snippet's container, a conversation's or
    /// collection's own ID); nil for other kinds.
    public var collapseKey: UUID? {
        switch kind {
        case .message, .snippet: container
        case .conversation, .collection: UUID(uuidString: id)
        default: nil
        }
    }

    /// `<kind>:<id>`, the index's group.
    public var group: String { "\(kind.rawValue):\(id)" }

    /// Compact text kept in the sealed manifest: `p=<uuid>;c=<uuid>;d=<seconds>;r`.
    var encoded: String {
        var parts: [String] = []
        if let paperID { parts.append("p=" + paperID.wire) }
        if let container { parts.append("c=" + container.wire) }
        if let date { parts.append("d=" + String(Int64(date.timeIntervalSince1970.rounded()))) }
        if byReader { parts.append("r") }
        return parts.joined(separator: ";")
    }

    /// The info of `group` from its manifest text; nil for a group that isn't an item's.
    init?(group: String, encoded: String?) {
        guard let colon = group.firstIndex(of: ":"), let kind = SearchItemKind(rawValue: String(group[..<colon])) else { return nil }
        self.kind = kind; id = String(group[group.index(after: colon)...])
        paperID = nil; container = nil; date = nil; byReader = false
        for part in (encoded ?? "").split(separator: ";") {
            if part == "r" { byReader = true; continue }
            guard part.count > 2, part.dropFirst().first == "=" else { continue }
            let value = String(part.dropFirst(2))
            switch part.first {
            case "p": paperID = UUID(uuidString: value)
            case "c": container = UUID(uuidString: value)
            case "d": date = Int64(value).map { Date(timeIntervalSince1970: Double($0)) }
            default: break
            }
        }
    }
}

/// One item's words in the index's fields (title 6, tags 3, notes 2, body 1; FullTextRanking), with its info.
public struct SearchItem: Equatable, Sendable {
    /// Changes when what an item indexes changes (its fields per kind): every item is then indexed again.
    public static let format = 1

    public var info: SearchItemInfo
    public var title: String
    public var tags: String
    public var notes: String
    public var body: String

    public init(info: SearchItemInfo, title: String = "", tags: String = "", notes: String = "", body: String = "") {
        self.info = info; self.title = title; self.tags = tags; self.notes = notes; self.body = body
    }

    public var kind: SearchItemKind { info.kind }
    public var group: String { info.group }

    /// The fields as the index takes them.
    public var fields: [FullTextField: String] { [.title: title, .tags: tags, .notes: notes, .body: body] }

    /// One metadata-part document: no per-item text file is written (excerpts come from the source).
    public func document(fingerprint: String) -> FullTextDocument {
        FullTextDocument(id: .init(group: group, part: .metadata), fingerprint: fingerprint, fields: fields, info: info.encoded)
    }

    /// A fingerprint of everything indexed (for items rebuilt from their source on every pass).
    public var contentFingerprint: String {
        var hasher = SHA256()
        hasher.update(data: Data("i\(Self.format)/t\(FullTextTokenizer.version)".utf8))
        for text in [title, tags, notes, body, info.encoded] {
            hasher.update(data: Data([0x1F])); hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A fingerprint from something that changes exactly when the item does (an immutable event's ID, a file and its
    /// date), so an unchanged item is never rebuilt to compare.
    public static func fingerprint(_ parts: String...) -> String {
        "i\(format)t\(FullTextTokenizer.version):" + parts.joined(separator: "|")
    }
}

// MARK: - Items from their sources

public extension SearchItem {
    /// A conversation: its title, the paper it is about, the passage it began from.
    static func conversation(id: UUID, title: String, paperID: UUID?, paperTitle: String?, passage: String?, date: Date?) -> SearchItem {
        SearchItem(info: SearchItemInfo(kind: .conversation, id: id.wire, paperID: paperID, date: date),
                   title: title, tags: paperTitle ?? "", notes: passage ?? "")
    }

    /// A question or an answer: its readable text (`SearchText.chat`).
    static func message(eventID: UUID, conversationID: UUID, paperID: UUID?, text: String, byReader: Bool, date: Date?) -> SearchItem {
        SearchItem(info: SearchItemInfo(kind: .message, id: eventID.wire, paperID: paperID, container: conversationID, date: date, byReader: byReader),
                   body: SearchText.chat(text))
    }

    /// A diagram, a visual answer or a figure breakdown in a chat: its title, labels and notes.
    static func diagram(id: UUID, diagram: ChatDiagram, conversationID: UUID?, paperID: UUID?, date: Date?) -> SearchItem {
        SearchItem(info: SearchItemInfo(kind: .diagram, id: id.wire, paperID: paperID, container: conversationID, date: date),
                   title: diagram.title, body: SearchText.diagram(diagram))
    }

    /// A kept equation explanation (`fileName` without `.sealed`): its label and paper, the symbols, their meanings.
    static func equation(fileName: String, answer: EquationAnswer) -> SearchItem? {
        guard let subject = answer.subject else { return nil }
        let symbols = answer.symbols?.symbols ?? []
        let tags = symbols.map { ([$0.symbol] + ($0.latex.map { [SearchText.math($0)] } ?? [])).joined(separator: " ") }.joined(separator: "\n")
        let body = (symbols.map(\.meaning) + [SearchText.chat(answer.text)]).filter { !$0.isEmpty }.joined(separator: "\n")
        return SearchItem(info: SearchItemInfo(kind: .equation, id: fileName, paperID: subject.paperID, date: subject.savedAt),
                          title: subject.label + " · " + subject.paperTitle, tags: tags, notes: SearchText.chat(answer.symbols?.summary ?? ""), body: body)
    }

    /// A kept figure explanation: label and paper, the parts' names, the walkthrough.
    static func figure(fileName: String, answer: FigureAnswer) -> SearchItem? {
        guard let subject = answer.subject, FigureAnswer.isShownFigureAction(subject.action) else { return nil }
        let sections = answer.walkthrough?.sections ?? []
        let tags = sections.map { [$0.label, $0.title].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n")
        let body = (sections.map { SearchText.chat($0.text) } + [SearchText.chat(answer.text)]).filter { !$0.isEmpty }.joined(separator: "\n")
        return SearchItem(info: SearchItemInfo(kind: .figure, id: fileName, paperID: subject.paperID, date: subject.savedAt),
                          title: subject.label + " · " + subject.paperTitle, tags: tags,
                          notes: SearchText.chat(answer.walkthrough?.summary ?? ""), body: body)
    }

    /// A kept paper AI Explainer: the paper, Key concepts' names, the summary, the lines and links.
    static func paperExplainer(fileName: String, answer: PaperExplainerAnswer) -> SearchItem? {
        guard let subject = answer.subject else { return nil }
        let items = (answer.explainer?.background ?? []) + (answer.explainer?.ideas ?? [])
        let body = (items.map { SearchText.chat($0.line) } + (answer.explainer?.links ?? []).map(\.label) + [SearchText.chat(answer.text)])
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return SearchItem(info: SearchItemInfo(kind: .paperExplainer, id: fileName, paperID: subject.paperID, date: subject.savedAt),
                          title: "AI Explainer · " + subject.paperTitle, tags: items.map(\.name).joined(separator: "\n"),
                          notes: SearchText.chat(answer.explainer?.summary ?? ""), body: body)
    }

    /// A snippet collection: its name.
    static func collection(id: UUID, name: String, date: Date?) -> SearchItem {
        SearchItem(info: SearchItemInfo(kind: .collection, id: id.wire, date: date), title: name)
    }

    /// A snippet: its collection's name and source in tags (so "quick atten" finds it, and a collection's name alone ranks
    /// the collection first), the comment in notes, its quotations, the reading's text under it and recognised text in body.
    static func snippet(_ record: NoteEntryRecord, collection: String, paperID: UUID?, extra: [String], recognised: String?, date: Date?) -> SearchItem {
        var tags = [collection]
        if let source = record.source {
            tags.append(source.title)
            if let section = source.section { tags.append(section) }
            if let label = source.label { tags.append(label) }
        }
        var body: [String] = []
        if let quote = record.quote { body.append(quote) }
        if let quote = record.anchor?.quote, quote != record.quote { body.append(quote) }
        body += extra.map(SearchText.math)
        if let recognised, !recognised.isEmpty { body.append(recognised) }
        return SearchItem(info: SearchItemInfo(kind: .snippet, id: record.entryID.wire, paperID: paperID, container: record.noteID, date: date),
                          tags: tags.filter { !$0.isEmpty }.joined(separator: "\n"), notes: record.comment,
                          body: body.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
