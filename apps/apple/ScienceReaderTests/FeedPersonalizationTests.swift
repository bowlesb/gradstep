import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// For you and the reader's topics in the Feed (owner feedback on build 21; docs/architecture/PERSONALIZED_FEED.md):
/// which chips show, what a response teaches the app, the Topics and Popularity columns and their orders.
@MainActor
final class FeedPersonalizationTests: XCTestCase {
    private func results(_ rows: [[String: Any]]) throws -> [DiscoveryResult] {
        let json = rows.map { row -> [String: Any] in
            var value: [String: Any] = ["revision": 1, "title": "T", "authors": ["Mei Lin", "Jonas Weber"], "categories": ["cs.LG"]]
            value.merge(row) { _, new in new }
            return value
        }
        return try JSONDecoder().decode([DiscoveryResult].self, from: JSONSerialization.data(withJSONObject: json))
    }

    private let topics = [FeedTopic(name: "RL for reasoning", kind: "combined", papers: 41), FeedTopic(name: "Tokenization", papers: 9)]

    func testChipsLeadWithForYouAndTheReadersTopicsAndKeepCategoriesWithoutIt() {
        let categories = ["cs.CL", "cs.LG", "stat.ML"]
        var personal = FeedPersonalization(available: true, topics: topics)
        XCTAssertEqual(FeedChips.chips(personal: personal, categories: categories, selected: .forYou).map(\.title),
                       ["For you", "RL for reasoning", "Tokenization"], "no broad categories among the chips")
        XCTAssertEqual(FeedChips.chips(personal: personal, categories: categories, selected: .category("cs.CL")).map(\.title),
                       ["For you", "RL for reasoning", "Tokenization", "Natural language processing"],
                       "a category picked from More topics shows while selected")
        XCTAssertEqual(FeedChips.chips(personal: personal, categories: categories, selected: .forYou).map(\.id),
                       ["feed.forYou", "feed.interest.RL for reasoning", "feed.interest.Tokenization"])
        personal.available = nil
        XCTAssertEqual(FeedChips.chips(personal: personal, categories: categories, selected: .forYou).first?.title, "For you",
                       "not known yet: For you is tried first")
        personal.available = false
        XCTAssertEqual(FeedChips.chips(personal: personal, categories: categories, selected: .category("cs.CL")).map(\.selection),
                       categories.map(FeedSelection.category), "without For you: the categories, exactly as before")
        XCTAssertEqual(FeedChips.moreTopics(categories: ["cs.CL", "stat.ML"]).prefix(3), ["cs.CL", "stat.ML", "cs.CV"],
                       "the library's categories first, then core ones, one per name (cs.LG is Machine learning, like stat.ML)")
    }

    func testResponsesTeachWhetherForYouIsOfferedAndItsTopics() {
        var personal = FeedPersonalization()
        XCTAssertTrue(personal.allows(.forYou), "unknown: try For you")
        personal.note(FeedInfo(forYou: true, coldStart: false, topics: topics), for: .forYou)
        XCTAssertEqual(personal, FeedPersonalization(available: true, topics: topics))
        XCTAssertTrue(personal.allows(.topic("Tokenization")))
        XCTAssertFalse(personal.allows(.topic("Gone")), "a topic no longer offered falls back to For you")
        personal.note(FeedInfo(forYou: true, topic: FeedTopic(name: "Tokenization")), for: .topic("Tokenization"))
        XCTAssertEqual(personal.topics, topics, "a topic response keeps the chips")
        personal.note(FeedInfo(forYou: true), for: .category("cs.CL"))
        XCTAssertEqual(personal.available, true)
        personal.note(nil, for: .category("cs.CL"))
        XCTAssertEqual(personal, FeedPersonalization(available: false), "a category response without the flag: not offered")
        XCTAssertFalse(personal.allows(.forYou))
        XCTAssertTrue(personal.allows(.category("cs.CL")))
        personal.note(FeedInfo(forYou: true, coldStart: true, topics: []), for: .forYou)
        XCTAssertTrue(personal.coldStart)
    }

    func testPersonalizationIsKeptOnTheDevice() throws {
        let name = "FeedPersonalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(FeedPersonalization.load(from: defaults), FeedPersonalization())
        FeedPersonalization(available: true, topics: topics).save(to: defaults)
        let restored = FeedPersonalization.load(from: defaults)
        XCTAssertEqual(restored.available, true)
        XCTAssertEqual(restored.topics.map(\.name), ["RL for reasoning", "Tokenization"])
        XCTAssertEqual(restored.topics.first?.kind, "combined")
        FeedPersonalization(available: false).save(to: defaults)
        XCTAssertEqual(FeedPersonalization.load(from: defaults), FeedPersonalization(available: false))
        defaults.set([["topic", String(repeating: "x", count: 41)], ["topic"]], forKey: FeedPersonalization.topicsKey)
        XCTAssertEqual(FeedPersonalization.load(from: defaults).topics, [], "malformed saved chips are ignored")
    }

    func testTopicsPopularityAndWhyLine() throws {
        let rows = try results([
            ["source_id": "2610.00001", "topics": ["State space models", "Tokenization", "Long context", "Transformers"], "upvotes": 162,
             "reason": ["kind": "tag", "label": "SSMs", "text": "In your tag: SSMs"]],
            ["source_id": "2610.00002", "categories": ["cs.CL"], "upvotes": 1],
            ["source_id": "2610.00003"],
        ])
        XCTAssertEqual(FeedFormat.topics(rows[0]), ["State space models", "Tokenization", "Long context"])
        XCTAssertEqual(FeedFormat.topics(rows[1]), ["Natural language processing"], "an older server: arXiv topics")
        XCTAssertEqual(FeedFormat.topic(rows[0]), "State space models")
        XCTAssertEqual(FeedFormat.popularity(rows[0]), "▲ 162")
        XCTAssertNil(FeedFormat.popularity(rows[2]), "unknown is shown as a dash, never as zero")
        XCTAssertEqual(FeedFormat.spokenPopularity(rows[0]), "162 upvotes on Hugging Face Papers")
        XCTAssertEqual(FeedFormat.spokenPopularity(rows[1]), "1 upvote on Hugging Face Papers")
        XCTAssertEqual(FeedFormat.spokenPopularity(rows[2]), "Popularity unknown")
        XCTAssertEqual(FeedFormat.subtitle(rows[0]), "In your tag: SSMs · Lin et al.")
        XCTAssertEqual(FeedFormat.subtitle(rows[1]), "Lin et al.")
    }

    func testPopularityAndSuggestedOrders() throws {
        let rows = try results([
            ["source_id": "2610.00001", "upvotes": 5], ["source_id": "2610.00002"], ["source_id": "2610.00003", "upvotes": 162],
            ["source_id": "2610.00004", "upvotes": 5], ["source_id": "2610.00005", "upvotes": 0],
        ])
        func order(_ key: FeedSortKey, ascending: Bool) -> [String] {
            FeedFormat.ordered(rows, by: PaperTableSort(key: key, ascending: ascending)).map(\.sourceID)
        }
        XCTAssertEqual(order(.popularity, ascending: false), ["2610.00003", "2610.00001", "2610.00004", "2610.00005", "2610.00002"],
                       "most upvoted first; ties keep the server's order; unknown last")
        XCTAssertEqual(order(.popularity, ascending: true), ["2610.00005", "2610.00001", "2610.00004", "2610.00003", "2610.00002"],
                       "unknown stays last when reversed")
        XCTAssertEqual(order(.suggested, ascending: false), rows.map(\.sourceID), "Suggested is the server's ranking")
        XCTAssertEqual(FeedTableColumn.defaultSort(personal: true), PaperTableSort(key: .suggested, ascending: false))
        XCTAssertEqual(FeedTableColumn.defaultSort(personal: false), PaperTableSort(key: .published, ascending: false))
        XCTAssertEqual(FeedSortKey.offered(personal: false), [.published, .popularity, .title, .topic, .authors])
        XCTAssertEqual(FeedSortKey.offered(personal: true).first, .suggested)
        XCTAssertFalse(FeedSortKey.popularity.ascendingFirst, "most popular first")
    }

    func testPopularityAppearsOnceForReadersWhoChoseColumnsBeforeIt() throws {
        let name = "FeedColumns.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func load() -> ColumnChoice<FeedTableColumn> {
            ColumnChoice.load(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault, regularDefault: FeedTableColumn.regularDefault,
                              introduced: FeedTableColumn.introduced, from: defaults)
        }
        // Build 21's saved choice (the owner's: Topic, Published, arXiv ID on the phone).
        defaults.set("topic,published,arxiv", forKey: "feed.columns.compact")
        defaults.set("topic,published,authors", forKey: "feed.columns.regular")
        var choice = load()
        XCTAssertEqual(choice.compact, [.popularity, .topic, .published, .arxiv], "the new default column shows once")
        XCTAssertEqual(choice.regular, [.popularity, .topic, .published, .authors])
        choice.compact.remove(.popularity)
        choice.save(to: defaults)
        XCTAssertEqual(load().compact, [.topic, .published, .arxiv], "turning it off sticks")
        XCTAssertEqual(load().regular, [.popularity, .topic, .published, .authors])
        XCTAssertEqual(FeedTableColumn.topic.rawValue, "topic", "saved choices name Topics by its old key")
        XCTAssertEqual(FeedTableColumn.topic.title, "Topics")
        XCTAssertEqual(FeedTableColumn.choosable.first, .popularity)
    }
}
