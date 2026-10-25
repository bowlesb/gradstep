import Foundation
import ScienceReaderCore

// For you and the reader's topics in the Feed (docs/architecture/PERSONALIZED_FEED.md; owner feedback on build 21:
// "Machine learning and artificial intelligence are too generic, it needs to be specific to the individual tastes and
// their nuances"). The server ranks and chooses the topics from what it already holds for the library; the app only
// remembers whether For you is offered and the last topic chips, so the Feed opens on For you with its chips at once.

/// What the Feed shows.
enum FeedSelection: Hashable, Sendable {
    /// The reader's ranked suggestions.
    case forYou
    /// One of the reader's topics ("RL for reasoning", "Tokenization", one of their own tags), ranked for them.
    case topic(String)
    /// An arXiv category's newest papers, as before For you.
    case category(String)

    /// For you and topics are ranked for the reader; categories are newest first.
    var isPersonal: Bool { if case .category = self { false } else { true } }

    /// The chip's accessibility identifier ("feed.forYou", "feed.interest.Tokenization", "feed.topic.cs.LG").
    var identifier: String {
        switch self {
        case .forYou: "feed.forYou"
        case .topic(let name): "feed.interest.\(name)"
        case .category(let category): "feed.topic.\(category)"
        }
    }

    /// The view's name for its page kept on the device (`FeedPageStore`): "for_you", "topic:<name>", "category:<code>".
    var storageKey: String {
        switch self {
        case .forYou: "for_you"
        case .topic(let name): "topic:\(name)"
        case .category(let category): "category:\(category)"
        }
    }
}

/// For you on this device: whether the server offers it to this reader (learned from Feed responses), the reader's
/// topic chips from the last For you response, and whether For you had nothing to go on yet.
struct FeedPersonalization: Equatable, Sendable {
    /// nil: not known yet, so the Feed tries For you once; false: not offered (the category chips, as before).
    var available: Bool?
    var topics: [FeedTopic] = []
    var coldStart = false

    static let availabilityKey = "feed.forYou"
    static let topicsKey = "feed.forYouTopics"

    /// Whether a selection can be shown: For you and topics only while For you may be offered.
    func allows(_ selection: FeedSelection) -> Bool {
        switch selection {
        case .forYou: available != false
        case .topic(let name): available != false && topics.contains { $0.name == name }
        case .category: true
        }
    }

    /// What a Feed response says: For you is offered exactly when the response carries `feed.for_you`; For you itself
    /// brings the reader's current topic chips.
    mutating func note(_ info: FeedInfo?, for selection: FeedSelection) {
        available = info?.forYou == true
        if available == false { topics = []; coldStart = false; return }
        if selection == .forYou, let info { topics = info.topics; coldStart = info.coldStart }
    }

    static func load(from defaults: UserDefaults) -> Self {
        var value = Self()
        switch defaults.string(forKey: availabilityKey) { case "yes": value.available = true; case "no": value.available = false; default: break }
        let saved = defaults.array(forKey: topicsKey) as? [[String]] ?? []
        value.topics = saved.prefix(12).compactMap { pair in
            guard pair.count == 2, (1...40).contains(pair[1].count) else { return nil }
            return FeedTopic(name: pair[1], kind: pair[0])
        }
        return value
    }

    func save(to defaults: UserDefaults) {
        if let available { defaults.set(available ? "yes" : "no", forKey: Self.availabilityKey) } else { defaults.removeObject(forKey: Self.availabilityKey) }
        defaults.set(topics.map { [$0.kind, $0.name] }, forKey: Self.topicsKey)
    }
}

/// One chip in the Feed's header.
struct FeedChip: Identifiable, Hashable {
    let selection: FeedSelection
    let title: String
    var id: String { selection.identifier }
}

enum FeedChips {
    /// The header's chips. With For you: For you, the reader's topics, and a category the reader picked from More topics
    /// (shown while it is selected). Without: the library's categories, exactly as before For you.
    static func chips(personal: FeedPersonalization, categories: [String], selected: FeedSelection) -> [FeedChip] {
        guard personal.available != false else {
            return categories.map { FeedChip(selection: .category($0), title: ArxivTopics.name(for: $0)) }
        }
        var chips = [FeedChip(selection: .forYou, title: "For you")]
        chips += personal.topics.map { FeedChip(selection: .topic($0.name), title: $0.name) }
        if case .category(let category) = selected { chips.append(FeedChip(selection: selected, title: ArxivTopics.name(for: category))) }
        return chips
    }

    /// More topics: the broad arXiv categories, reachable with For you (the library's categories first, then the core ML
    /// ones), one per name.
    static func moreTopics(categories: [String]) -> [String] {
        var names = Set<String>(), result: [String] = []
        for category in categories + ["cs.LG", "cs.CL", "cs.CV", "cs.AI", "stat.ML", "cs.RO", "cs.IR", "cs.NE"]
        where names.insert(ArxivTopics.name(for: category)).inserted { result.append(category) }
        return result
    }
}
